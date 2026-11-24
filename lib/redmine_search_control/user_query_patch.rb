# frozen_string_literal: true

module RedmineSearchControl
  # Administration -> Users: the "Name, email or login" filter is always on the page, as the single
  # "User" field of the users list before Redmine 6, and an empty value means "do not filter" instead of
  # the "cannot be blank" error.
  #
  # Prepended to UserQuery (init.rb). Does not touch the page template, only the query.
  module UserQueryPatch
    FIELD = 'name'

    # Every new users query (first visit, "Clear", from the session) gets the filter
    def initialize(*args)
      super
      search_control_ensure_name_filter
    end

    # "Apply" replaces the filters with the ones from the form: put the field back if it was unticked
    def build_from_params(params, defaults = {})
      super
      search_control_ensure_name_filter
      self
    end

    # An empty filter is not an error...
    def validate_query_filters
      search_control_without_blank_name { super() }
    end

    # ...and adds no condition
    def statement
      search_control_without_blank_name { super() }
    end

    private

    def search_control_ensure_name_filter
      return unless new_record? && filters.is_a?(Hash)
      return if filters.key?(FIELD)

      add_filter(FIELD, '~', [''])
    end

    def search_control_blank_name?
      return false unless filters.is_a?(Hash) && filters.key?(FIELD)
      # "any" and "none" need no value
      return false if %w[* !*].include?(operator_for(FIELD))

      Array(values_for(FIELD)).all? { |value| value.to_s.strip.empty? }
    end

    # Runs the block as if the empty name filter were not there, then puts it back for the form
    def search_control_without_blank_name
      return yield unless search_control_blank_name?

      removed = filters.delete(FIELD)
      begin
        yield
      ensure
        filters[FIELD] = removed
      end
    end
  end
end
