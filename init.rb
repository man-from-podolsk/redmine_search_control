# frozen_string_literal: true

# Search Control: search in Redmine lists the way it worked before Redmine 6.
#
#   Administration -> Users   the "Name, email or login" filter is always shown and may be left empty
#                             (in Redmine 6+ the old "User" field became an optional query filter that
#                             fails with "cannot be blank" when empty)

Redmine::Plugin.register :redmine_search_control do
  name 'Search Control'
  author 'man-from-podolsk'
  description 'Users list: the name/email/login filter is always shown and an empty value does not filter.'
  version '1.0.0'
  url 'https://github.com/man-from-podolsk/redmine_search_control'
  requires_redmine version_or_higher: '6.0.0'
end

UserQuery.prepend(RedmineSearchControl::UserQueryPatch) unless UserQuery < RedmineSearchControl::UserQueryPatch
