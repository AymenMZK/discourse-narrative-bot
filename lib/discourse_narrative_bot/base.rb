module DiscourseNarrativeBot
  class Base
    include Actions

    class InvalidTransitionError < StandardError; end

    def input(input, user, post: nil, topic_id: nil, skip: false)
      new_post = nil
      @post = post
      @topic_id = topic_id
      @skip = skip

      synchronize(user) do
        @user = user
        @data = get_data(user) || {}
        @state = (@data[:state] && @data[:state].to_sym) || :begin
        @input = input
        opts = {}

        begin
          opts = transition
        rescue InvalidTransitionError
          # For given input, no transition for current state
          return
        end

        next_state = opts[:next_state]
        action = opts[:action]

        if next_instructions = opts[:next_instructions]
          @next_instructions = next_instructions
        end

        begin
          old_data = @data.dup
          new_post = (@skip && @state != :end) ? skip_tutorial(next_state) : self.send(action)

          if new_post
            old_state = old_data[:state]
            @state = @data[:state] = next_state
            @data[:last_post_id] = new_post.id
            set_data(@user, @data)

            if self.class.private_method_defined?("init_#{next_state}") &&
              old_state.to_s != next_state.to_s

              self.send("init_#{next_state}")
            end

            if next_state == :end
              end_reply
              cancel_timeout_job(user)

              completed = Set.new(get_data(@user)[:completed])
              completed << self.class.to_s

              set_data(@user,
                topic_id: new_post.topic_id,
                state: :end,
                track: self.class.to_s,
                completed: completed
              )
            end
          end
        rescue => e
          @data = old_data
          set_data(@user, @data)
          raise e
        end
      end

      new_post
    end

    def reset_bot
      not_implemented
    end

    def set_data(user, value)
      DiscourseNarrativeBot::Store.set(user.id, value)
    end

    def get_data(user)
      DiscourseNarrativeBot::Store.get(user.id)
    end

    def notify_timeout(user)
      @data = get_data(user) || {}

      if post = Post.find_by(id: @data[:last_post_id])
        reply_to(post, I18n.t("discourse_narrative_bot.timeout.message",
          username: user.username,
          skip_trigger: TrackSelector::SKIP_TRIGGER,
          reset_trigger: "#{TrackSelector::RESET_TRIGGER} #{self.class::RESET_TRIGGER}",
        ))
      end
    end

    def certificate(type = nil)
      options = {
        user_id: @user.id,
        date: Time.zone.now.strftime('%b %d %Y'),
        host: Discourse.base_url,
        format: :svg
      }

      options.merge!(type: type) if type
      src = DiscourseNarrativeBot::Engine.routes.url_helpers.certificate_url(options)
      "<img class='discobot-certificate' src='#{src}' width='650' height='464' alt='#{I18n.t("#{self.class::I18N_KEY}.certificate.alt")}'>"
    end

    private

    def set_state_data(key, value)
      @data[@state] ||= {}
      @data[@state][key] = value
      set_data(@user, @data)
    end

    def get_state_data(key)
      @data[@state] ||= {}
      @data[@state][key]
    end

    def reset_data(user, additional_data = {})
      old_data = get_data(user)
      new_data = additional_data
      new_data[:completed] = old_data[:completed] if old_data && old_data[:completed]
      set_data(user, new_data)
      new_data
    end

    def transition
      options = self.class::TRANSITION_TABLE.fetch(@state).dup
      input_options = options.fetch(@input)
      options.merge!(input_options) unless @skip
      options
    rescue KeyError
      raise InvalidTransitionError.new
    end

    def skip_tutorial(next_state)
      return unless valid_topic?(@post.topic_id)

      fake_delay

      if next_state != :end
        reply = reply_to(@post, instance_eval(&@next_instructions))
        enqueue_timeout_job(@user)
        reply
      else
        @post
      end
    end

    def valid_topic?(topic_id)
      topic_id == @data[:topic_id]
    end

    def not_implemented
      raise 'Not implemented.'
    end
  end
end
