require 'spec_helper'
require 'vtysh'

RSpec.describe "Command ordering" do
  context "when creating peer-groups" do
    it "puts peer-group definitions before bgp listen commands" do
      source = ""
      target = <<~CONFIG
        router bgp 65001
         bgp listen range 10.0.0.0/8 peer-group SERVERS
         neighbor SERVERS peer-group
         neighbor SERVERS remote-as 65001
         neighbor CLIENTS peer-group
         neighbor CLIENTS remote-as 65002
         bgp listen range 192.168.0.0/16 peer-group CLIENTS
        exit
      CONFIG

      commands = Vtysh::Diff.commands(source, target)
      
      # Extract commands related to SERVERS peer-group and listen range
      servers_peer_group_cmd = commands.find { |cmd| cmd.include?("SERVERS peer-group") }
      servers_listen_range_cmd = commands.find { |cmd| cmd.include?("bgp listen range 10.0.0.0/8") }
      
      # Extract commands related to CLIENTS peer-group and listen range
      clients_peer_group_cmd = commands.find { |cmd| cmd.include?("CLIENTS peer-group") }
      clients_listen_range_cmd = commands.find { |cmd| cmd.include?("bgp listen range 192.168.0.0/16") }
      
      # Check order in the commands list - peer-group must come before bgp listen
      servers_peer_group_index = commands.index(servers_peer_group_cmd)
      servers_listen_range_index = commands.index(servers_listen_range_cmd)
      
      clients_peer_group_index = commands.index(clients_peer_group_cmd)
      clients_listen_range_index = commands.index(clients_listen_range_cmd)
      
      # SERVERS peer-group should come before 10.0.0.0/8 listen range
      expect(servers_peer_group_index).to be < servers_listen_range_index
      
      # CLIENTS peer-group should come before 192.168.0.0/16 listen range
      expect(clients_peer_group_index).to be < clients_listen_range_index
    end
  end

  context "when using route-maps" do
    it "correctly formats route-map match commands as separate arguments" do
      source = ""
      target = <<~CONFIG
        route-map ALLOW_TRUSTED permit 10
         match ip address prefix-list TRUSTED
        route-map DENY_ALL deny 20
      CONFIG

      commands = Vtysh::Diff.commands(source, target)
      
      # Find command with match statement
      match_cmd = commands.find { |cmd| cmd.include?("match ip address") }
      
      # It should use the separate argument format
      expect(match_cmd).to include('-c "route-map ALLOW_TRUSTED permit 10" -c "match ip address prefix-list TRUSTED"')
      expect(match_cmd).not_to include('-c "route-map ALLOW_TRUSTED permit 10 match ip address prefix-list TRUSTED"')
    end
  end

  context "with complex BGP configuration" do
    it "orders the commands correctly" do
      source = ""
      target = <<~CONFIG
        router bgp 65001
         bgp router-id 10.0.0.1
         neighbor CLIENTS peer-group
         neighbor SERVERS peer-group
         neighbor 10.1.1.1 remote-as 65002
         neighbor CLIENTS remote-as 65003
         neighbor SERVERS remote-as 65001
         bgp listen range 10.0.0.0/8 peer-group SERVERS
         bgp listen range 192.168.0.0/16 peer-group CLIENTS
         address-family ipv4 unicast
          neighbor 10.1.1.1 route-map INBOUND in
          neighbor 10.1.1.1 route-map OUTBOUND out
          neighbor CLIENTS route-map CLIENT_FILTER in
          network 192.168.1.0/24
          network 192.168.2.0/24
         exit-address-family
        exit
      CONFIG

      commands = Vtysh::Diff.commands(source, target)
      
      # Extract specific commands that need ordering checks
      clients_peer_group_cmd = commands.find { |cmd| cmd.include?("CLIENTS peer-group") }
      clients_remote_as_cmd = commands.find { |cmd| cmd.include?("CLIENTS remote-as") }
      
      servers_peer_group_cmd = commands.find { |cmd| cmd.include?("SERVERS peer-group") }
      servers_remote_as_cmd = commands.find { |cmd| cmd.include?("SERVERS remote-as") }
      
      # Get the indices for comparison
      clients_peer_group_index = commands.index(clients_peer_group_cmd)
      clients_remote_as_index = commands.index(clients_remote_as_cmd)
      
      servers_peer_group_index = commands.index(servers_peer_group_cmd)
      servers_remote_as_index = commands.index(servers_remote_as_cmd)
      
      # Check peer-group comes before remote-as for each peer
      expect(clients_peer_group_index).to be < clients_remote_as_index
      expect(servers_peer_group_index).to be < servers_remote_as_index
      
      # Check peer-group and remote-as come before listen commands
      clients_listen_cmd = commands.find { |cmd| cmd.include?("bgp listen") && cmd.include?("CLIENTS") }
      servers_listen_cmd = commands.find { |cmd| cmd.include?("bgp listen") && cmd.include?("SERVERS") }
      
      clients_listen_index = commands.index(clients_listen_cmd)
      servers_listen_index = commands.index(servers_listen_cmd)
      
      expect(clients_peer_group_index).to be < clients_listen_index
      expect(servers_peer_group_index).to be < servers_listen_index
    end
  end
  
  context "with route-map and prefix-list dependencies" do
    it "generates correctly ordered commands" do
      source = ""
      target = <<~CONFIG
        ip prefix-list TRUSTED seq 5 permit 10.0.0.0/8 le 32
        ip prefix-list TRUSTED seq 10 permit 192.168.0.0/16 le 32
        ip prefix-list RESTRICTED seq 5 permit 172.16.0.0/12 le 32
        
        route-map ALLOW_TRUSTED permit 10
         match ip address prefix-list TRUSTED
        route-map ALLOW_TRUSTED deny 20
        
        route-map RESTRICT permit 10
         match ip address prefix-list RESTRICTED
        
        router bgp 65001
         neighbor 10.1.1.1 peer-group
         neighbor 10.1.1.1 remote-as 65002
         neighbor 10.1.1.1 route-map ALLOW_TRUSTED in
         neighbor 10.1.1.1 route-map RESTRICT out
        exit
      CONFIG

      commands = Vtysh::Diff.commands(source, target)
      
      # The prefix-lists and route-maps should be created before they're referenced
      prefix_list_idx = commands.find_index { |cmd| cmd.include?("ip prefix-list TRUSTED") }
      route_map_idx = commands.find_index { |cmd| cmd.include?("route-map ALLOW_TRUSTED permit") }
      route_map_ref_idx = commands.find_index { |cmd| cmd.include?("neighbor") && cmd.include?("route-map ALLOW_TRUSTED") }
      
      expect(prefix_list_idx).not_to be_nil
      expect(route_map_idx).not_to be_nil
      expect(route_map_ref_idx).not_to be_nil
      
      # Route-map should be created before it's referenced
      expect(route_map_idx).to be < route_map_ref_idx
    end
  end
end 