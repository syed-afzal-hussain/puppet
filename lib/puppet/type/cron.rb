require 'etc'
require 'facter'
require 'puppet/type/state'
require 'puppet/filetype'
require 'puppet/type/parsedtype'

module Puppet
    # Model the actual cron jobs.  Supports all of the normal cron job fields
    # as parameters, with the 'command' as the single state.  Also requires a
    # completely symbolic 'name' paremeter, which gets written to the file
    # and is used to manage the job.
    newtype(:cron) do
        # A base class for all of the Cron parameters, since they all have
        # similar argument checking going on.  We're stealing the base class
        # from parsedtype, and we should probably subclass Cron from there,
        # but it was just too annoying to do.
        class CronParam < Puppet::State::ParsedParam
            class << self
                attr_accessor :boundaries
            end

            # A method used to do parameter input handling.  Converts integers
            # in string form to actual integers, and returns the value if it's
            # an integer or false if it's just a normal string.
            def numfix(num)
                if num =~ /^\d+$/
                    return num.to_i
                elsif num.is_a?(Integer)
                    return num
                else
                    return false
                end
            end

            # Verify that a number is within the specified limits.  Return the
            # number if it is, or false if it is not.
            def limitcheck(num, lower, upper)
                if num >= lower and num <= upper
                    return num
                else
                    return false
                end
            end

            # Verify that a value falls within the specified array.  Does case
            # insensitive matching, and supports matching either the entire word
            # or the first three letters of the word.
            def alphacheck(value, ary)
                tmp = value.downcase
                
                # If they specified a shortened version of the name, then see
                # if we can lengthen it (e.g., mon => monday).
                if tmp.length == 3
                    ary.each_with_index { |name, index|
                        if name =~ /#{tmp}/i
                            return index
                        end
                    }
                else
                    if ary.include?(tmp)
                        return ary.index(tmp)
                    end
                end

                return false
            end

            def should_to_s
                if @should.empty?
                    return "*"
                else
                    return @should.join(",")
                end
            end

            # The method that does all of the actual parameter value
            # checking; called by all of the +param<name>=+ methods.
            # Requires the value, type, and bounds, and optionally supports
            # a boolean of whether to do alpha checking, and if so requires
            # the ary against which to do the checking.
            munge do |value|
                return value unless self.class.boundaries
                lower, upper = self.class.boundaries
                retval = nil
                if num = numfix(value)
                    retval = limitcheck(num, lower, upper)
                elsif respond_to?(:alpha)
                    # If it has an alpha method defined, then we check
                    # to see if our value is in that list and if so we turn
                    # it into a number
                    retval = alphacheck(value, alpha())
                end

                if retval
                    return retval.to_s
                else
                    raise Puppet::Error, "%s is not a valid %s" %
                        [value, self.class.name]
                end
            end
        end
        # Somewhat uniquely, this state does not actually change anything -- it
        # just calls +@parent.sync+, which writes out the whole cron tab for
        # the user in question.  There is no real way to change individual cron
        # jobs without rewriting the entire cron file.
        #
        # Note that this means that managing many cron jobs for a given user
        # could currently result in multiple write sessions for that user.
        newstate(:command, CronParam) do
            desc "The command to execute in the cron job.  The environment
                provided to the command varies by local system rules, and it is
                best to always provide a fully qualified command.  The user's
                profile is not sourced when the command is run, so if the
                user's environment is desired it should be sourced manually."
        end

        newstate(:minute, CronParam) do
            self.boundaries = [0, 59]
            desc "The minute at which to run the cron job.
                Optional; if specified, must be between 0 and 59, inclusive."
        end

        newstate(:hour, CronParam) do
            self.boundaries = [0, 23]
            desc "The hour at which to run the cron job. Optional;
                if specified, must be between 0 and 23, inclusive."
        end

        newstate(:weekday, CronParam) do
            def alpha
                %w{sunday monday tuesday wednesday thursday friday saturday}
            end
            self.boundaries = [0, 6]
            desc "The weekday on which to run the command.
                Optional; if specified, must be between 0 and 6, inclusive, with
                0 being Sunday, or must be the name of the day (e.g., Tuesday)."
        end

        newstate(:month, CronParam) do
            def alpha
                %w{january february march april may june july
                    august september october november december}
            end
            self.boundaries = [1, 12]
            desc "The month of the year.  Optional; if specified
                must be between 1 and 12 or the month name (e.g., December)."
        end

        newstate(:monthday, CronParam) do
            self.boundaries = [1, 31]
            desc "The day of the month on which to run the
                command.  Optional; if specified, must be between 1 and 31."
        end

        newparam(:name) do
            desc "The symbolic name of the cron job.  This name
                is used for human reference only."

            isnamevar
        end

        newparam(:user) do
            desc "The user to run the command as.  This user must
                be allowed to run cron jobs, which is not currently checked by
                Puppet."

            # This validation isn't really a good idea, since the user might
            # be created by Puppet, in which case the validation will fail.
            validate do |user|
                require 'etc'

                begin
                    obj = Etc.getpwnam(user)
                    parent.uid = obj.uid
                rescue ArgumentError
                    raise Puppet::Error, "User %s not found" % user
                end

                user
            end
        end

        @doc = "Installs and manages cron jobs.  All fields except the command 
            and the user are optional, although specifying no periodic
            fields would result in the command being executed every
            minute.  While the name of the cron job is not part of the actual
            job, it is used by Puppet to store and retrieve it.  If you specify
            a cron job that matches an existing job in every way except name,
            then the jobs will be considered equivalent and the new name will
            be permanently associated with that job.  Once this association is
            made and synced to disk, you can then manage the job normally."

        @instances = {}
        @tabs = {}

        case Facter["operatingsystem"].value
        when "Solaris":
            @filetype = Puppet::FileType.filetype(:suntab)
        else
            @filetype = Puppet::FileType.filetype(:crontab)
        end

        class << self
            attr_accessor :filetype
        end

        attr_accessor :uid

        # Override the Puppet::Type#[]= method so that we can store the instances
        # in per-user arrays.  Then just call +super+.
        def self.[]=(name, object)
            self.instance(object)
            super
        end

        # In addition to removing the instances in @objects, Cron has to remove
        # per-user cron tab information.
        def self.clear
            @instances = {}
            @tabs = {}
            super
        end

        # Override the default Puppet::Type method, because instances
        # also need to be deleted from the @instances hash
        def self.delete(child)
            if @instances.include?(child[:user])
                if @instances[child[:user]].include?(child)
                    @instances[child[:user]].delete(child)
                end
            end
            super
        end

        # Return the fields found in the cron tab.
        def self.fields
            return [:minute, :hour, :monthday, :month, :weekday, :command]
        end

        # Return the header placed at the top of each generated file, warning
        # users that modifying this file manually is probably a bad idea.
        def self.header
%{#This file was autogenerated at #{Time.now} by puppet.  While it
# can still be managed manually, it is definitely not recommended.
# Note particularly that the comments starting with 'Puppet Name' should
# not be deleted, as doing so could cause duplicate cron jobs.\n}
        end

        # Store a new instance of a cron job.  Called from Cron#initialize.
        def self.instance(obj)
            user = obj[:user]
            if @instances.include?(user)
                unless @instances[obj[:user]].include?(obj)
                    @instances[obj[:user]] << obj
                end
            else
                @instances[obj[:user]] = [obj]
            end
        end

        # Parse a user's cron job into individual cron objects.
        #
        # Autogenerates names for any jobs that don't already have one; these
        # names will get written back to the file.
        #
        # This method also stores existing comments, and it stores all cron
        # jobs in order, mostly so that comments are retained in the order
        # they were written and in proximity to the same jobs.
        def self.parse(user, text)
            count = 0
            hash = {}
            name = nil
            unless @instances.include?(user)
                @instances[user] = []
            end
            text.chomp.split("\n").each { |line|
                case line
                when /^# Puppet Name: (\w+)$/: name = $1
                when /^#/:
                    # add other comments to the list as they are
                    @instances[user] << line 
                else
                    if match = /^(\S+) (\S+) (\S+) (\S+) (\S+) (.+)$/.match(line)
                        fields().zip(match.captures).each { |param, value|
                            unless value == "*"
                                unless param == :command
                                    if value =~ /,/
                                        value = value.split(",")
                                    end
                                end
                                hash[param] = value
                            end
                        }
                    else
                        raise Puppet::Error, "Could not match '%s'" % line
                    end

                    cron = nil
                    unless name
                        Puppet.info "Autogenerating name for %s" % hash[:command]
                        name = "cron-%s" % hash.object_id
                    end

                    unless hash.include?(:command)
                        raise Puppet::DevError, "No command for %s" % name
                    end
                    # if the cron already exists with that name...
                    if cron = Puppet.type(:cron)[name]
                        # do nothing...
                    elsif tmp = @instances[user].reject { |obj|
                                ! obj.is_a?(self)
                            }.find { |obj|
                                obj.should(:command) == hash[:command]
                            }
                        # if we can find a cron whose spec exactly matches

                        # we now have a cron job whose command exactly matches
                        # let's see if the other fields match
                        txt = tmp.to_cron.sub(/#.+\n/,'')

                        if txt == line
                            cron = tmp
                        end
                    else
                        # create a new cron job, since no existing one
                        # seems to match
                        cron = self.create(
                            :name => name
                        )
                    end

                    hash.each { |param, value|
                        cron.is = [param, value]
                    }
                    hash.clear
                    name = nil
                    count += 1
                end
            }
        end

        # Retrieve a given user's cron job, using the @filetype's +retrieve+
        # method.  Returns nil if there was no cron job; else, returns the
        # number of cron instances found.
        def self.retrieve(user)
            @tabs[user] ||= @filetype.new(user)
            text = @tabs[user].read
            if $? != 0
                # there is no cron file
                return nil
            else
                self.parse(user, text)
            end
        end

        # Remove a user's cron tab.
        def self.remove(user)
            @tabs[user] ||= @filetype.new(user)
            @tabs[user].remove
        end

        # Store the user's cron tab.  Collects the text of the new tab and
        # sends it to the +@filetype+ module's +write+ function.  Also adds
        # header warning users not to modify the file directly.
        def self.store(user)
            @tabs[user] ||= @filetype.new(user)
            if @instances.include?(user)
                @tabs[user].write(self.tab(user))
            else
                Puppet.notice "No cron instances for %s" % user
            end
        end

        # Collect all Cron instances for a given user and convert them
        # into literal text.
        def self.tab(user)
            if @instances.include?(user)
                return self.header() + @instances[user].collect { |obj|
                    if obj.is_a? self
                        obj.to_cron
                    else
                        obj.to_s
                    end
                }.join("\n") + "\n"

            else
                Puppet.notice "No cron instances for %s" % user
            end
        end

        # Return the last time a given user's cron tab was loaded.  Could
        # be used for reducing writes, but currently is not.
        def self.loaded?(user)
            if @tabs.include?(user)
                return @loaded[user].loaded
            else
                return nil
            end
        end

        # Override the default Puppet::Type method because we need to call
        # the +@filetype+ retrieve method.
        def retrieve
            unless @parameters.include?(:user)
                raise Puppet::Error, "You must specify the cron user"
            end

            self.class.retrieve(@parameters[:user])
            self.eachstate { |st| st.retrieve }
        end

        # Write the entire user's cron tab out.
        def store
            self.class.store(self[:user])
        end

        # Convert the current object a cron-style string.  Adds the cron name
        # as a comment above the cron job, in the form '# Puppet Name: <name>'.
        def to_cron
            hash = {:command => @states[:command].should || @states[:command].is }

            # Collect all of the values that we have
            self.class.fields().reject { |f| f == :command }.each { |param|
                if @states.include?(param)
                    hash[param] = @states[param].should_to_s
                end
            }

            return "# Puppet Name: %s\n" % self.name +
                self.class.fields.collect { |f|
                    hash[f] || "*"
                }.join(" ")
        end
    end
end

# $Id$
