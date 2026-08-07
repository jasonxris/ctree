# frozen_string_literal: true

require_relative "lib/ctree/version"

Gem::Specification.new do |spec|
  spec.name = "ctree"
  spec.version = Ctree::VERSION
  spec.authors = ["Martin Yosifov"]
  spec.homepage = "https://github.com/mytrak/ctree"
  spec.license = "MIT"
  spec.summary = "Replicate a Docker Compose dev tree as a sibling git worktree."
  spec.description = "Replicate any Docker-compose based git repo as a sibling git worktree, " \
                     "with its own branch, docker volumes, and a tailored .env, so that " \
                     "multiple branches can run side by side without interfering with " \
                     "each other's state."

  spec.files = Dir.glob("lib/**/*.{rb,yml}") + %w[README.md LICENSE CHANGELOG.md]
  spec.bindir = "bin"
  spec.executables = ["ctree"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.0"
end
