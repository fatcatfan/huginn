module Agents
  class PubsubhubbubSubscriberAgent < Agent
    cannot_receive_events!

    default_schedule "every_12h"

    description do <<-MD
      The PubSubHubbub Subscriber Agent uses a webhook to get push notifications of updates to RSS feeds
      using an external hub. Use it instead of scheduled polling for RSS Agent.

      This agent runs on a schedule in order to periodically renew the subscription lease.

      Options:

        * `secret` - A token that the host will provide for authentication.
        * `expected_receive_period_in_days` - How often you expect to receive
          events this way. Used to determine if the agent is working.
        * `feed_url` - URL of the content to which the user wishes to subscribe.
          This will typically be an RSS feed, but depending on the hub used
          other content may be acceptable.
        * `hub_url` - URL of hub which will facilitate the subscription and push
          updates to this agent.
      MD
    end

    event_description do
      <<-MD
        The event payload is the raw body of a successful POST from the hub.
        {
            "source" : "hub" or "seed"
            "format" : "mime/type"
            "raw" : "..."
        }
      MD
    end


    def default_options
      { "secret" => "supersecretstring",
        "expected_receive_period_in_days" => 1,
        "feed_url" => "http://www.polygon.com/rss/index.xml",
        "hub_url" => "https://pubsubhubbub.superfeedr.com"
      }
    end


    def check
        #if we have a valid lease, check if it's time to renew it. (less than 24 hours fom expiring?)
        #it's important to renew the lease *before* it expires to ensure no updated feed content is missed.
        #if we don't have a valid lease, initiate a new subscription by calling 'do_subscribe'
        do_subscribe
    end


    def receive_web_request(params, method, format)
      # check the secret
      secret = params.delete('secret')
      return ["Not Authorized", 401] unless secret == interpolated['secret']

      if method.downcase == "get"
        #(un)subscribe validation or denial
        #
        #if it's "subscribe" and we don't currently have a valid lease, then
        #fetch feed_url and emit to generate the first event (verify hub doesn't duplicate this)
        if params['hub.topic'] == options['feed_url']
            if params['hub.mode'] == "denied" && memory['subscribe']
                errors.add(:base, "Subscription was denied:\n" + params['hub.reason'] + "\n" + request.headers["Location"])
                return ["Not really OK, but... OK", 200]
            elsif params['hub.mode'] == "subscribe" && memory['subscribe']
                response = faraday.get(options['feed_url']) #it would probably be better to do this asynchronously, send the 'hub.challenge' response to hub before seeding first event
                if response.success?
                    create_event(   payload: {
                                                source: "seed",
                                                format: response.headers['Content-Type'],
                                                raw: response.body
                                             })
                else
                    errors.add(:base, "Unable to retrieve feed_url.")
                end
                memory['lease_end'] == params['hub.lease_seconds']  #actually need to convert this into a date/time, because server reboots could lose any renewal schedule
                return [params['hub.challenge'], 200]
            elsif params['hub.mode'] == "unsubscribe" && !memory['subscribe']
                return [params['hub.challenge'], 200]
            end
        else
            log "Received unexpected get:\n" + params['hub.topic']
            return ["Bad Request", 400]
        end

      elsif method.downcase == "post"
        if memory['subscribe']
            if (request.headers["Link"].include? options['feed_url']) && (request.headers["Link"].include? options['hub_url'])
                #new content, echo to event
                create_event(   payload: {
                                            source: "hub",
                                            format: format,
                                            raw: request.raw_post
                                         })
                return ["OK", 200]
            else
                log "Received unexpected post:\n" + request.headers["Link"] + "\n" + request.raw_post
                return ["Not Authorized", 401]
            end
        else
            log "Received post when not subscribed:\n" + request.headers["Link"] + "\n" + request.raw_post
            return ["Not Authorized", 401]
        end
      end
      log "Received unsupported request method: " + method
      ["Method Not Allowed", 405]
    end


    def working?
      event_created_within?(interpolated['expected_receive_period_in_days']) && !recent_error_logs?
    end


    def validate_options
      unless options['secret'].present?
        errors.add(:base, "Must specify a secret for 'Authenticating' requests")
      end
      unless options['expected_update_period_in_days'].present? && options['expected_update_period_in_days'].to_i > 0
        errors.add(:base, "Please provide 'expected_update_period_in_days' to indicate how many days can pass without an update before this Agent is considered to not be working")
      end
      unless options['feed_url'].present?
        errors.add(:base, "You can't subscribe to nothing, please provide a feed_url")
      end
      unless options['hub_url'].present?
        errors.add(:base, "A hub_url is required")
      end
    end


    def do_subscribe
        log "do_subscribe"
        memory['subscribe'] = true
        #POST to hub_url, application/x-www-form-urlencoded
        #hub.callback
        #REQUIRED. The webhook URL of this agent.
        #https://#{ENV['DOMAIN']}/users/#{user.id}/web_requests/#{id}/#{options['secret']}
        #hub.mode
        #REQUIRED. The literal string "subscribe".
        #hub.topic
        #REQUIRED. The feed_url that the subscriber wishes to subscribe to.
        #
    end


    def do_unsubscribe
        log "do_unsubscribe"
        memory['subscribe'] = false
        #is there any useful way to ever execute this code?
        #unsubcribing would be polite to the hub, but the lease will expire eventually
        #
        #POST to hub_url, application/x-www-form-urlencoded
        #hub.callback
        #REQUIRED. The webhook URL of this agent.
        #https://#{ENV['DOMAIN']}/users/#{user.id}/web_requests/#{id}/#{options['secret']}
        #hub.mode
        #REQUIRED. The literal string "unsubscribe".
        #hub.topic
        #REQUIRED. The feed_url that the subscriber wishes to unsubscribe from.
    end
  end
end
