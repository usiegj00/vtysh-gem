require_relative "lib/vtysh/version"

Gem::Specification.new do |spec|
  spec.name = "vtysh"
  spec.version = Vtysh::VERSION
  spec.authors = ["Jonathan Siegel"]
  spec.email = ["<248302+usiegj00@users.noreply.github.com>"]
  spec.summary = "Handles SONiC vtysh commandfile format"
  spec.description = "A gem that accepts two vtysh configuration states and returns the commands needed to transition from one to the other"
  spec.homepage = "http://github.com/usiegj00/vtysh-gem"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.files = Dir["lib/**/*", "bin/*", "LICENSE", "README.md"]
  spec.bindir = "bin"
  spec.executables = ["vtysh-transform"]
  spec.require_paths = ["lib"]
end 