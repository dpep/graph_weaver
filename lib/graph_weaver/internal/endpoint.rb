# typed: true
# frozen_string_literal: true

require "uri"

module GraphWeaver
  module Internal
    # The endpoint as the gem is willing to SAY it — in a log line, an
    # exception, an APM payload. Every one of those outlives the request, and a
    # url can carry a credential two ways: its userinfo, and a query parameter
    # (`?access_token=…`). Transport#url stays the real endpoint — that is
    # where requests go, and what `graphql: :wire` stubs on.
    module Endpoint
      class << self
        def safe(url)
          uri = URI(url.to_s)
          # the overwhelmingly common case: a url with nothing to hide, said
          # back exactly as it was configured
          return url.to_s unless uri.userinfo || uri.query

          query = uri.query
          userinfo = uri.userinfo
          uri.query = nil
          uri.fragment = nil # never sent to a server; nothing to report

          # URI#userinfo= is a no-op for nil, so the swap happens on the text —
          # "//<userinfo>@" appears once, right after the scheme
          text = uri.to_s
          text = text.sub("//#{userinfo}@", "//#{GraphWeaver::FILTERED}@") if userinfo
          text = "#{text}?#{scrub_query(query)}" if query
          text
        rescue URI::Error
          # a url we can't take apart is one we can't promise to have scrubbed
          GraphWeaver::FILTERED
        end

        private

        # Which query parameters are secret is the same question
        # GraphWeaver.filter_parameters already answers for variables, so a
        # scrubbed log reads the same either side of the seam. Split rather
        # than decoded and re-encoded: every parameter that stays is printed
        # exactly as it was sent.
        def scrub_query(query)
          query.split("&").map do |pair|
            name, value = pair.split("=", 2)
            next pair if value.nil? || !Redact.filtered?(URI.decode_www_form_component(name))

            "#{name}=#{GraphWeaver::FILTERED}"
          end.join("&")
        end
      end
    end
  end
end
