# frozen_string_literal: true

desc "Updates the `friends` program"
command :update do |update|
  update.action do |global_options|
    # rubocop:disable Lint/AssignmentInCondition
    if match = `gem search friends`.match(/^friends\s\(([^\)]+)\)$/)
      # rubocop:enable Lint/AssignmentInCondition
      remote_version = match[1]
      if Semverse::Version.coerce(remote_version) >
         Semverse::Version.coerce(Friends::VERSION)
        `gem update friends && gem cleanup friends`

        unless global_options[:quiet]
          if $?.success?
            puts Paint["Updated to friends #{remote_version}", :bold, :green]
          else
            puts Paint["Error updating to friends version #{remote_version}", :bold, :red]
          end
        end
      else
        unless global_options[:quiet]
          puts Paint["Already up-to-date (#{Friends::VERSION})", :bold, :green]
        end
      end
    end
  end
end
