# frozen_string_literal: true

# Reuse bin/bench-load's synthesizer without running its main body.
_src = File.read(File.expand_path("../../bin/bench-load", __dir__))
_body = _src[/^module Synth$.*?^end$/m] or raise "Synth not found in bin/bench-load"
eval(_body, TOPLEVEL_BINDING, "bench-load:Synth") # rubocop:disable Security/Eval
