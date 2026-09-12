# activesupport is not a dependency of this gem, but a railtie only ever runs
# where it is — so the one class GraphWeaver inherits from gets a stand-in of
# the same shape, here rather than in a spec file because railtie_spec and
# log_subscriber_spec both need it before their first example.
#
# Only what the gem names. NOT ActiveSupport::Notifications: other gems
# feature-detect that constant, so an example that needs it stubs it for its
# own duration. What the real class does with a subscriber — attach_to's
# "#{method}.#{namespace}" pattern and Subscriber#call dispatching on the half
# before the dot — a stand-in can only mirror, so it is checked against the
# real gem outside the bundle whenever this seam changes (CLAUDE.md's
# throwaway-app rule; the railtie is the same kind of blind spot).
module ActiveSupport; end unless defined?(ActiveSupport)

unless defined?(ActiveSupport::LogSubscriber)
  ActiveSupport.const_set(:LogSubscriber, Class.new do
    # upstream subscribes one notification pattern per public method; all a
    # spec can ask is which namespace it was handed
    def self.attach_to(namespace) = attached << namespace
    def self.attached = @attached ||= []

    # upstream's default — GraphWeaver::LogSubscriber overrides it, and that
    # override is the thing worth testing
    def logger = nil
  end)
end
