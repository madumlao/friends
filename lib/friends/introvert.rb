# frozen_string_literal: true
# Introvert is the internal handler for the friends script. It is designed to be
# able to be used directly within another Ruby program, without needing to call
# the command-line script explicitly.

require "friends/activity"
require "friends/friend"
require "friends/location"
require "friends/friends_error"

module Friends
  class Introvert
    DEFAULT_FILENAME = "./friends.md".freeze
    ACTIVITIES_HEADER = "### Activities:".freeze
    FRIENDS_HEADER = "### Friends:".freeze
    LOCATIONS_HEADER = "### Locations:".freeze
    GRAPH_DATE_FORMAT = "%b %Y".freeze # Used as the param for date.strftime().

    # @param filename [String] the name of the friends Markdown file
    def initialize(filename: DEFAULT_FILENAME)
      @filename = filename

      # Read in the input file. It's easier to do this now and optimize later
      # than try to overly be clever about what we read and write.
      read_file
    end

    # Write out the friends file with cleaned/sorted data.
    def clean
      File.open(@filename, "w") do |file|
        file.puts(ACTIVITIES_HEADER)
        @activities.sort.each { |act| file.puts(act.serialize) }
        file.puts # Blank line separating activities from friends.
        file.puts(FRIENDS_HEADER)
        @friends.sort.each { |friend| file.puts(friend.serialize) }
        file.puts # Blank line separating friends from locations.
        file.puts(LOCATIONS_HEADER)
        @locations.sort.each { |location| file.puts(location.serialize) }
      end

      @filename
    end

    # Add a friend.
    # @param name [String] the name of the friend to add
    # @raise [FriendsError] when a friend with that name is already in the file
    # @return [Friend] the added friend
    def add_friend(name:)
      if friend_with_exact_name(name)
        raise FriendsError, "Friend named #{name} already exists"
      end

      begin
        friend = Friend.deserialize(name)
      rescue Serializable::SerializationError => e
        raise FriendsError, e
      end

      @friends << friend

      friend # Return the added friend.
    end

    # Add an activity.
    # @param serialization [String] the serialized activity
    # @return [Activity] the added activity
    def add_activity(serialization:)
      begin
        activity = Activity.deserialize(serialization)
      rescue Serializable::SerializationError => e
        raise FriendsError, e
      end

      activity.highlight_description(introvert: self) if activity.description
      @activities.unshift(activity)

      activity # Return the added activity.
    end

    # Add a location.
    # @param name [String] the serialized location
    # @return [Location] the added location
    def add_location(name:)
      if @locations.any? { |location| location.name == name }
        raise FriendsError, "Location \"#{name}\" already exists"
      end

      begin
        location = Location.deserialize(name)
      rescue Serializable::SerializationError => e
        raise FriendsError, e
      end

      @locations << location

      location # Return the added location.
    end

    # Rename an existing added friend.
    # @param old_name [String] the name of the friend
    # @param new_name [String] the new name of the friend
    # @raise [FriendsError] if 0 or 2+ friends match the given name
    # @return [Friend] the existing friend
    def rename_friend(old_name:, new_name:)
      friend = friend_with_name_in(old_name.strip)
      @activities.each do |activity|
        activity.update_name(old_name: friend.name, new_name: new_name.strip)
      end
      friend.rename(new_name.strip)
      friend
    end

    # Add a nickname to an existing friend.
    # @param name [String] the name of the friend
    # @param nickname [String] the nickname to add to the friend
    # @raise [FriendsError] if 0 or 2+ friends match the given name
    # @return [Friend] the existing friend
    def add_nickname(name:, nickname:)
      friend = friend_with_name_in(name)
      friend.add_nickname(nickname.strip)
      friend
    end

    # Remove a nickname from an existing friend and write out the new friends
    #   file.
    # @param name [String] the name of the friend
    # @param nickname [String] the nickname to remove from the friend
    # @raise [FriendsError] if 0 or 2+ friends match the given name
    # @return [Friend] the existing friend
    def remove_nickname(name:, nickname:)
      friend = friend_with_name_in(name)
      friend.remove_nickname(nickname.strip)
      friend
    end

    # List all friend names in the friends file.
    # @return [Array] a list of all friend names
    def list_friends
      @friends.map(&:name)
    end

    # List your favorite friends.
    # @param limit [Integer] the number of favorite friends to return, or nil
    #   for no limit
    # @return [Array] a list of the favorite friends' names and activity
    #   counts
    def list_favorites(limit:)
      if !limit.nil? && limit < 1
        raise FriendsError, "Favorites limit must be positive or unlimited"
      end

      set_n_activities! # Set n_activities for all friends.

      # Sort the results, with the most favorite friend first.
      results = @friends.sort_by { |friend| -friend.n_activities }

      # If we need to, trim the list.
      results = results.take(limit) unless limit.nil?

      max_str_size = results.map(&:name).map(&:size).max
      results.map.with_index(0) do |friend, index|
        name = friend.name.ljust(max_str_size)
        parenthetical = "(#{friend.n_activities}#{' activities' if index == 0})"
        "#{name} #{parenthetical}"
      end
    end

    # List all activity details.
    # @param limit [Integer] the number of activities to return, or nil for no
    #   limit
    # @param with [String] the name of a friend to filter by, or nil for
    #   unfiltered
    # @param location_name [String] the name of a location to filter by, or nil
    #  for  unfiltered
    # @return [Array] a list of all activity text values
    # @raise [FriendsError] if 0 or 2+ friends match the given `with` text
    def list_activities(limit:, with:, location_name:)
      acts = @activities

      # Filter by friend name if argument is passed.
      unless with.nil?
        friend = friend_with_name_in(with)
        acts = acts.select { |act| act.includes_friend?(friend: friend) }
      end

      # Filter by location name if argument is passed.
      unless location_name.nil?
        location = location_with_name_in(location_name)
        acts = acts.select { |act| act.includes_location?(location: location) }
      end

      # If we need to, trim the list.
      acts = acts.take(limit) unless limit.nil?

      acts.map(&:display_text)
    end

    # List all location names in the friends file.
    # @return [Array] a list of all location names
    def list_locations
      @locations.map(&:name)
    end

    # Find data points for graphing activities over time.
    # Optionally filter by a friend to see a given relationship over time.
    #
    # The returned hash uses the following format:
    #   {
    #     "Jan 2015" => 3, # The number of activities during each month.
    #     "Feb 2015" => 0,
    #     "Mar 2015" => 9
    #   }
    # The keys of the hash are all of the months (inclusive) between the first
    # and last month in which activities have been recorded.
    #
    # @param name [String] the name of the friend to use
    # @return [Hash{String => Fixnum}]
    # @raise [FriendsError] if 0 or 2+ friends match the given name
    def graph(name: nil)
      if name
        friend = friend_with_name_in(name) # Find the friend by name.

        # Filter out activities that don't include the given friend.
        acts = @activities.select { |act| act.includes_friend?(friend: friend) }
      else
        acts = @activities
      end

      # Initialize the table of activities to have all of the months of that
      # friend's activity range (including months in the middle of the range
      # with no relevant activities).
      act_table = {}
      (acts.last.date..acts.first.date).each do |date|
        act_table[date.strftime(GRAPH_DATE_FORMAT)] = 0
      end

      acts.each do |activity|
        month = activity.date.strftime(GRAPH_DATE_FORMAT)
        act_table[month] += 1
      end
      act_table
    end

    # Suggest friends to do something with.
    #
    # The returned hash uses the following format:
    #   {
    #     distant: ["Distant Friend 1 Name", "Distant Friend 2 Name", ...],
    #     moderate: ["Moderate Friend 1 Name", "Moderate Friend 2 Name", ...],
    #     close: ["Close Friend 1 Name", "Close Friend 2 Name", ...]
    #   }
    #
    # @return [Hash{String => Array<String>}]
    def suggest
      set_n_activities! # Set n_activities for all friends.

      # Sort our friends, with the least favorite friend first.
      sorted_friends = @friends.sort_by(&:n_activities)

      output = Hash.new { |h, k| h[k] = [] }

      # Set initial value in case there are no friends and the while loop is
      # never entered.
      output[:distant] = []

      # First, get not-so-good friends.
      while !sorted_friends.empty? && sorted_friends.first.n_activities < 2
        output[:distant] << sorted_friends.shift.name
      end

      output[:moderate] = sorted_friends.slice!(0, sorted_friends.size * 3 / 4).
                          map!(&:name)
      output[:close] = sorted_friends.map!(&:name)

      output
    end

    ###################################################################
    # Methods below this are only used internally and are not tested. #
    ###################################################################

    # Sets the n_activities field on each friend.
    def set_n_activities!
      # Construct a hash of friend name to frequency of appearance.
      freq_table = Hash.new { |h, k| h[k] = 0 }
      @activities.each do |activity|
        activity.friend_names.each do |friend_name|
          freq_table[friend_name] += 1
        end
      end

      # Remove names that are not in the friends list.
      freq_table.each do |name, count|
        friend = friend_with_exact_name(name)
        friend.n_activities = count if friend # Do nothing if name not valid.
      end
    end

    # Get a regex friend map.
    #
    # The returned hash uses the following format:
    #   {
    #     /regex/ => [list of friends matching regex]
    #   }
    #
    # This hash is sorted (because Ruby's hashes are ordered) by decreasing
    # regex key length, so the key /Jacob Evelyn/ appears before /Jacob/.
    #
    # @return [Hash{Regexp => Array<Friends::Friend>}]
    def regex_friend_map
      @friends.each_with_object(Hash.new { |h, k| h[k] = [] }) do |friend, hash|
        friend.regexes_for_name.each do |regex|
          hash[regex] << friend
        end
      end.sort_by { |k, _| -k.to_s.size }.to_h
    end

    # Get a regex location map.
    #
    # The returned hash uses the following format:
    #   {
    #     /regex/ => [list of friends matching regex]
    #   }
    #
    # This hash is sorted (because Ruby's hashes are ordered) by decreasing
    # regex key length, so the key /Paris, France/ appears before /Paris/.
    #
    # @return [Hash{Regexp => Array<Friends::Location>}]
    def regex_location_map
      @locations.each_with_object({}) do |location, hash|
        hash[location.regex_for_name] = location
      end.sort_by { |k, _| -k.to_s.size }.to_h
    end

    # Sets the likelihood_score field on each friend in `possible_matches`. This
    # score represents how likely it is that an activity containing the friends
    # in `matches` and containing a friend from each group in `possible_matches`
    # contains that given friend.
    # @param matches [Array<Friend>] the friends in a specific activity
    # @param possible_matches [Array<Array<Friend>>] an array of groups of
    #   possible matches, for example:
    #   [
    #     [Friend.new(name: "John Doe"), Friend.new(name: "John Deere")],
    #     [Friend.new(name: "Aunt Mae"), Friend.new(name: "Aunt Sue")]
    #   ]
    #   These groups will all contain friends with similar names; the purpose of
    #   this method is to give us a likelihood that a "John" in an activity
    #   description, for instance, is "John Deere" vs. "John Doe"
    def set_likelihood_score!(matches:, possible_matches:)
      combinations = (matches + possible_matches.flatten).
                     combination(2).
                     reject do |friend1, friend2|
                       (matches & [friend1, friend2]).size == 2 ||
                         possible_matches.any? do |group|
                           (group & [friend1, friend2]).size == 2
                         end
                     end

      @activities.each do |activity|
        names = activity.friend_names

        combinations.each do |group|
          if (names & group.map(&:name)).size == 2
            group.each { |friend| friend.likelihood_score += 1 }
          end
        end
      end
    end

    # @return [Integer] the total number of friends
    def total_friends
      @friends.size
    end

    # @return [Integer] the total number of activities
    def total_activities
      @activities.size
    end

    # @return [Integer] the number of days elapsed between
    #   the first and last activity
    def elapsed_days
      return 0 if @activities.size < 2
      sorted_activities = @activities.sort
      (sorted_activities.first.date - sorted_activities.last.date).to_i
    end

    private

    # Process the friends.md file and store its contents in internal data
    # structures.
    def read_file
      @friends = []
      @activities = []
      @locations = []

      return unless File.exist?(@filename)

      state = :unknown

      # Loop through all lines in the file and process them.
      File.foreach(@filename).with_index(1) do |line, line_num|
        line.chomp! # Remove trailing newline from each line.

        # Parse the line and update the parsing state.
        state = parse_line!(line, line_num: line_num, state: state)
      end
    end

    # Parse the given line, adding to the various internal data structures as
    # necessary.
    # @param line [String]
    # @param line_num [Integer] the 1-indexed file line number we're parsing
    # @param state [Symbol] the state of the parsing, one of:
    #   [:unknown, :reading_activities, :reading_friends, :reading_locations]
    # @return [Symbol] the updated state after parsing the given line
    def parse_line!(line, line_num:, state:)
      return :unknown if line == ""

      # If we're in an unknown state, look for a header to tell us what we're
      # parsing next.
      if state == :unknown
        PARSING_STAGES.each do |stage|
          if line == self.class.const_get("#{stage.id.to_s.upcase}_HEADER")
            return "reading_#{stage.id}".to_sym
          end
        end

        # If we made it here, we couldn't recognize a header.
        bad_line("Couldn't parse line.", line_num)
      end

      # If we made it this far, we're parsing objects in a class.
      stage = PARSING_STAGES.find { |s| state == "reading_#{s.id}".to_sym }

      begin
        instance_variable_get("@#{stage.id}") << stage.klass.deserialize(line)
      rescue FriendsError => e
        bad_line(e, line_num)
      end

      state
    end

    # Used internally by the parse_line! method above to associate stages with
    # the class to create.
    ParsingStage = Struct.new(:id, :klass)
    PARSING_STAGES = [
      ParsingStage.new(:activities, Activity),
      ParsingStage.new(:friends, Friend),
      ParsingStage.new(:locations, Location)
    ].freeze

    # @param name [String] the name of the friend to search for
    # @return [Friend] the friend whose name exactly matches the argument
    # @raise [FriendsError] if more than one friend has the given name
    def friend_with_exact_name(name)
      results = @friends.select { |friend| friend.name == name }

      case results.size
      when 0 then nil
      when 1 then results.first
      else raise FriendsError, "More than one friend named #{name}"
      end
    end

    # @param text [String] the name (or substring) of the friend to search for
    # @return [Friend] the friend that matches
    # @raise [FriendsError] if 0 or 2+ friends match the given text
    def friend_with_name_in(text)
      regex = Regexp.new(text, Regexp::IGNORECASE)
      friends = @friends.select { |friend| friend.name.match(regex) }

      case friends.size
      when 1
        # If exactly one friend matches, use that friend.
        return friends.first
      when 0 then raise FriendsError, "No friend found for \"#{text}\""
      else
        raise FriendsError,
              "More than one friend found for \"#{text}\": "\
                "#{friends.map(&:name).join(', ')}"
      end
    end

    # @param text [String] the name (or substring) of the location to search for
    # @return [Location] the location that matches
    # @raise [FriendsError] if 0 or 2+ location match the given text
    def location_with_name_in(text)
      regex = Regexp.new(text, Regexp::IGNORECASE)
      locations = @locations.select { |location| location.name.match(regex) }

      case locations.size
      when 1
        # If exactly one location matches, use that location.
        return locations.first
      when 0 then raise FriendsError, "No location found for \"#{text}\""
      else
        raise FriendsError,
              "More than one location found for \"#{text}\": "\
                "#{locations.map(&:name).join(', ')}"
      end
    end

    # Raise an error that a line in the friends file is malformed.
    # @param expected [String] the expected contents of the line
    # @param line_num [Integer] the line number
    # @raise [FriendsError] with a constructed message
    def bad_line(expected, line_num)
      raise FriendsError, "Expected \"#{expected}\" on line #{line_num}"
    end
  end
end
