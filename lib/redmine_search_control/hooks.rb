# frozen_string_literal: true

module RedmineSearchControl
  # Update notice on the Administration and Plugins pages
  class Hooks < Redmine::Hook::ViewListener
    # Administration and Plugins pages: a notice for administrators when GitHub has a newer version
    def view_layouts_base_content(context = {})
      controller = context[:controller]
      return '' unless controller && User.current.admin?
      return '' unless RedmineSearchControl::UpdateCheck.update_admin_page?(controller)

      data = RedmineSearchControl::UpdateCheck.status
      return '' unless RedmineSearchControl::UpdateCheck.update_available?(data)

      id = 'redmine_search_control_update_notice'
      html = content_tag(:div, RedmineSearchControl::UpdateCheck.render_notice(self, data, 'search_control'), class: 'flash warning', id: id)
      # Moved to the top of the page content
      html + javascript_tag("(function(){var n=document.getElementById('#{id}'),c=document.getElementById('content');" \
                            "if(n&&c){c.insertBefore(n,c.firstChild);}})();")
    end
  end
end
