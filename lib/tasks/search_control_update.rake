# frozen_string_literal: true

namespace :redmine do
  namespace :search_control do
    desc 'Checks GitHub for a newer version of redmine_search_control'
    task check_update: :environment do
      data = RedmineSearchControl::UpdateCheck.check!
      RedmineSearchControl::UpdateCheck.write_cache(data)
      if data['error']
        puts "Check failed: #{data['error']}"
        exit 1
      elsif RedmineSearchControl::UpdateCheck.update_available?(data)
        notice = RedmineSearchControl::UpdateCheck.notice(data)
        puts "Update available: #{notice[:installed]} -> #{notice[:latest] || "#{notice[:behind]} new commits"}"
        notice[:items].each { |item| puts "  - #{item}" }
        puts notice[:git] ? "git pull in plugins/#{notice[:folder]}" : "Archive: #{notice[:archive_url]}"
      else
        puts "Up to date (#{RedmineSearchControl::UpdateCheck.installed_version})"
      end
    end
  end
end
