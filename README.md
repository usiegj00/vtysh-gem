# Vtysh

A Ruby gem for handling SONiC vtysh configuration diffs. It accepts two configuration states and returns the commands needed to transition from one to the other.

## Installation

```ruby
gem 'vtysh'
```

## Usage

```ruby
require 'vtysh'

source_config = File.read('a.vtysh')
target_config = File.read('b.vtysh')

commands = Vtysh::Diff.commands(source_config, target_config)

puts commands
```

This will output commands with proper hierarchy preserved:

```
# BGP blocks are fully recreated
vtysh -c "configure" -c "no router bgp 65001"
vtysh -c "configure" -c "router bgp 65001" -c "bgp router-id 192.168.1.1" -c "neighbor 192.168.1.2 remote-as 65002" -c "exit"

# Individual commands for non-BGP configuration
vtysh -c "configure" -c "interface Ethernet0 description Primary"
```

## Features

- Generates hierarchical vtysh commands that maintain proper block structure
- Properly handles configuration blocks like `router bgp` and `address-family`
- Removes and recreates entire BGP blocks for clean configuration
- Route-map match commands are split into separate arguments
- Adds appropriate exit commands when needed
- Correctly removes entire configuration blocks with `no` prefix
- Includes `configure` terminal context as required by SONiC vtysh
- Ensures `neighbor peer-group` commands come before `bgp listen range` commands
- Ensures `neighbor remote-as` commands are processed before other neighbor attributes

## Command Ordering

The gem pays special attention to command ordering to meet SONiC vtysh requirements:

1. Peer-group definitions come before `bgp listen range` commands referencing them
2. For neighbors, `remote-as` commands always come before other attributes like route-maps, descriptions, etc.
3. When adding new neighbors, the ASN is defined first via the `remote-as` command
4. This prevents common errors like `% Specify remote-as or peer-group commands first`

## Block-Based Processing

The gem uses a block-based approach where:

1. BGP blocks are fully removed and recreated with clean settings
2. Route-map blocks handle match commands as separate arguments
3. Interface and other blocks are processed with proper context

This ensures:
- Complete configuration with proper command ordering
- Clean setup of complex structures like BGP routers
- Proper handling of nested contexts like address-family blocks

## License

The gem is available as open source under the terms of the MIT License. 