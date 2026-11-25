# frozen_string_literal: true

require 'json'
require 'net/http'
require 'fileutils'

module RedmineSearchControl
  # Daily check whether GitHub has newer commits than the installed copy.
  #
  # Copied installation (no .git): the version in init.rb on GitHub is compared with the installed one,
  # and the entries of CHANGELOG.md newer than the installed version are shown.
  # Installed with `git clone`: the installed commit is compared with the branch on GitHub instead.
  #
  # The request runs in a background thread at most once a day and never slows a page down; the result is
  # kept in tmp/redmine_search_control_update.json. Nothing is sent to GitHub except the request itself.
  module UpdateCheck
    REPO = 'man-from-podolsk/redmine_search_control'
    BRANCH = 'main'
    INTERVAL = 24 * 60 * 60
    RETRY_AFTER_ERROR = 3 * 60 * 60
    TIMEOUT = 5
    PLUGIN = :redmine_search_control

    @mutex = Mutex.new
    @running = false

    module_function

    # Cached result; starts a background refresh when it is old. Returns nil before the first check.
    # { 'checked_at' => Integer, 'behind' => Integer, 'commits' => [String], 'latest_version' => String,
    #   'changes' => [[version, [lines]]], 'local' => String, 'git' => Boolean, 'error' => String,
    #   'compare_url' => String }
    def status
      data = read_cache
      refresh_async if stale?(data)
      data
    end

    def update_available?(data = status)
      data.is_a?(Hash) && data['error'].nil? && data['behind'].to_i.positive?
    end

    def repo_url
      "https://github.com/#{REPO}"
    end

    def plugin_dir
      Redmine::Plugin.find(PLUGIN).directory
    rescue StandardError
      File.expand_path('../..', __dir__)
    end

    def installed_version
      Redmine::Plugin.find(PLUGIN).version.to_s
    rescue StandardError
      nil
    end

    # Commit of the installed copy, from .git without running git
    def local_commit
      git = File.join(plugin_dir, '.git')
      return nil unless File.directory?(git)

      head = File.read(File.join(git, 'HEAD')).strip
      return head if head.match?(/\A\h{40}\z/)

      ref = head.delete_prefix('ref: ').strip
      ref_file = File.join(git, ref)
      return File.read(ref_file).strip if File.file?(ref_file)

      packed = File.join(git, 'packed-refs')
      return nil unless File.file?(packed)

      File.foreach(packed) { |line| return line.split.first if line.strip.end_with?(" #{ref}") }
      nil
    rescue StandardError
      nil
    end

    # Synchronous check (used by the rake task and the background thread)
    def check!
      local = local_commit
      data = local ? compare(local) : compare_versions
      data.merge('checked_at' => Time.now.to_i, 'local' => local || installed_version, 'git' => !local.nil?)
    rescue StandardError => e
      { 'checked_at' => Time.now.to_i, 'error' => "#{e.class}: #{e.message}"[0, 200] }
    end

    def compare(local)
      json = get_json("https://api.github.com/repos/#{REPO}/compare/#{local}...#{BRANCH}")
      commits = Array(json['commits']).map { |c| c.dig('commit', 'message').to_s.lines.first.to_s.strip }.last(10).reverse
      { 'behind' => json['ahead_by'].to_i, 'commits' => commits, 'status' => json['status'],
        'compare_url' => "#{repo_url}/compare/#{local[0, 12]}...#{BRANCH}" }
    end

    def compare_versions
      text = get("https://raw.githubusercontent.com/#{REPO}/#{BRANCH}/init.rb")
      latest = text[/^\s*version\s+['"]([^'"]+)['"]/, 1]
      installed = installed_version
      raise 'no version in init.rb on GitHub' unless latest && installed

      newer = Gem::Version.new(latest) > Gem::Version.new(installed)
      changes = newer ? changelog_since(installed) : []
      { 'behind' => newer ? 1 : 0, 'commits' => [], 'latest_version' => latest, 'changes' => changes,
        'compare_url' => "#{repo_url}/blob/#{BRANCH}/CHANGELOG.md" }
    end

    # Sections of CHANGELOG.md ("## 1.1.0 ...") newer than the installed version
    def changelog_since(installed)
      text = get("https://raw.githubusercontent.com/#{REPO}/#{BRANCH}/CHANGELOG.md")
      parse_changelog(text).select { |version, _| Gem::Version.new(version) > Gem::Version.new(installed) }.first(5)
    rescue StandardError
      []
    end

    def parse_changelog(text)
      sections = []
      text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.each_line do |line|
        if (match = line.match(/^##\s+v?(\d+(?:\.\d+)+)/))
          sections << [match[1], []]
        elsif sections.any? && line.strip.start_with?('- ', '* ')
          sections.last[1] << line.strip.sub(/\A[-*]\s+/, '')
        elsif sections.any? && sections.last[1].any? && line.match?(/\A\s+\S/)
          # Continuation of a bullet wrapped onto the next line
          sections.last[1][-1] = "#{sections.last[1].last} #{line.strip}"
        end
      end
      sections
    end

    # What the notice shows: title values, list of changes, how to update
    def notice(data)
      sections = Array(data['changes'])
      # Version prefix only when the notice spans several versions; Markdown backticks removed
      lines = sections.flat_map do |version, items|
        items.map { |item| sections.size > 1 ? "#{version}: #{item.delete('`')}" : item.delete('`') }
      end
      lines = Array(data['commits']) if lines.empty?
      {
        name: (Redmine::Plugin.find(PLUGIN).name rescue PLUGIN.to_s),
        installed: installed_version,
        latest: data['latest_version'],
        behind: data['behind'].to_i,
        git: data['git'] == true,
        items: lines.first(8),
        migrate: lines.any? { |line| line.match?(/migrat|миграц/i) },
        folder: File.basename(plugin_dir),
        archive_url: archive_url,
        changes_url: data['compare_url']
      }
    end

    # HTML of the notice; view: anything with ActionView helpers (a view or a hook listener)
    def render_notice(view, data, prefix)
      n = notice(data)
      t = ->(key, **vars) { view.l("#{prefix}_update_#{key}", **vars) }
      title = n[:git] ? t.(:title_git, name: n[:name], count: n[:behind]) : t.(:title, name: n[:name], installed: n[:installed], latest: n[:latest])
      parts = [view.content_tag(:strong, title)]
      parts << view.content_tag(:ul, view.safe_join(n[:items].map { |item| view.content_tag(:li, item) }), style: 'margin: 4px 0;') if n[:items].any?
      how =
        if n[:git]
          view.safe_join([t.(:how_git), ' ', view.content_tag(:code, "cd plugins/#{n[:folder]} && git pull"), '. ', t.(:restart)])
        else
          view.safe_join([t.(:how_copy_1), ' ', view.link_to(t.(:archive), n[:archive_url]), ' ', t.(:how_copy_2, folder: n[:folder]), ' ', t.(:restart)])
        end
      parts << view.content_tag(:div, how)
      if n[:migrate]
        parts << view.content_tag(:div, view.safe_join([t.(:migrate), ' ',
                                                         view.content_tag(:code, "bundle exec rake redmine:plugins:migrate NAME=#{PLUGIN} RAILS_ENV=production")]))
      end
      parts << view.link_to(t.(:all_changes), n[:changes_url], target: '_blank', rel: 'noopener') if n[:changes_url]
      view.safe_join(parts)
    end

    # Pages where administrators see the notice
    def update_admin_page?(controller)
      case controller.controller_name
      when 'admin' then %w[index plugins].include?(controller.action_name)
      when 'settings' then controller.action_name == 'plugin' && controller.params[:id].to_s == PLUGIN.to_s
      else false
      end
    end

    # Archive of the current version, for copied installations
    def archive_url
      "#{repo_url}/archive/refs/heads/#{BRANCH}.zip"
    end

    def get_json(url)
      JSON.parse(get(url, 'application/vnd.github+json'))
    end

    def get(url, accept = '*/*')
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        request = Net::HTTP::Get.new(uri)
        request['Accept'] = accept
        request['User-Agent'] = "#{PLUGIN} update check"
        response = http.request(request)
        raise "HTTP #{response.code} from #{uri.host}" unless response.is_a?(Net::HTTPSuccess)

        # Net::HTTP returns binary; CHANGELOG.md is UTF-8 with Russian text
        response.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      end
    end

    def stale?(data)
      return true unless data.is_a?(Hash) && data['checked_at']
      # The installed copy changed (git pull or a new copy) since the last check
      return true if data['error'].nil? && data['local'] != (local_commit || installed_version)

      age = Time.now.to_i - data['checked_at'].to_i
      age > (data['error'] ? RETRY_AFTER_ERROR : INTERVAL)
    end

    def refresh_async
      @mutex.synchronize do
        return if @running

        @running = true
      end
      Thread.new do
        write_cache(check!)
      rescue StandardError => e
        Rails.logger&.warn("#{PLUGIN}: update check failed: #{e.message}")
      ensure
        @mutex.synchronize { @running = false }
      end
    end

    def cache_path
      File.join(Rails.root.to_s, 'tmp', "#{PLUGIN}_update.json")
    end

    def read_cache
      @memory = nil if @memory && @memory_mtime != (File.mtime(cache_path) rescue nil)
      return @memory if @memory

      return nil unless File.file?(cache_path)

      @memory_mtime = File.mtime(cache_path)
      @memory = JSON.parse(File.read(cache_path))
    rescue StandardError
      nil
    end

    def write_cache(data)
      FileUtils.mkdir_p(File.dirname(cache_path))
      tmp = "#{cache_path}.#{Process.pid}"
      File.write(tmp, JSON.generate(data))
      File.rename(tmp, cache_path)
      @memory = nil
    rescue StandardError => e
      Rails.logger&.warn("#{PLUGIN}: cannot save update check: #{e.message}")
    end
  end
end
