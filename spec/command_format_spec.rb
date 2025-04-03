require "spec_helper"
require 'vtysh'

RSpec.describe "Command formatting" do
  describe "Hierarchical commands" do
    it "formats BGP address-family commands with proper context hierarchy" do
      source = "!
router bgp 65001
 address-family ipv4 unicast
  network 10.0.1.0/24
 exit-address-family
exit
!"
      target = "!
router bgp 65001
 address-family ipv4 unicast
  network 10.0.2.0/24
 exit-address-family
exit
!"
      
      commands = Vtysh::Diff.commands(source, target)
      
      # Test adding a network in address-family
      add_cmd = commands.find { |cmd| cmd.include?('network 10.0.2.0/24') }
      expect(add_cmd).to eq('vtysh -c "configure" -c "router bgp 65001" -c "address-family ipv4 unicast" -c "network 10.0.2.0/24"')
      
      # Test removing a network in address-family
      remove_cmd = commands.find { |cmd| cmd.include?('no network 10.0.1.0/24') }
      expect(remove_cmd).to eq('vtysh -c "configure" -c "router bgp 65001" -c "address-family ipv4 unicast" -c "no network 10.0.1.0/24"')
    end
    
    it "formats BGP neighbor commands with proper context hierarchy" do
      source = "!
router bgp 65001
 neighbor 192.168.1.2 remote-as 65002
 neighbor 192.168.1.2 description OldPeer
exit
!"
      target = "!
router bgp 65001
 neighbor 192.168.1.2 remote-as 65002
 neighbor 192.168.1.2 description UpdatedPeer
 neighbor 192.168.1.3 remote-as 65003
exit
!"
      
      commands = Vtysh::Diff.commands(source, target)
      
      # Test neighbor description change
      update_cmd = commands.find { |cmd| cmd.include?('description UpdatedPeer') }
      expect(update_cmd).to eq('vtysh -c "configure" -c "router bgp 65001" -c "neighbor 192.168.1.2 description UpdatedPeer"')
      
      # Test new neighbor
      new_cmd = commands.find { |cmd| cmd.include?('neighbor 192.168.1.3') }
      expect(new_cmd).to eq('vtysh -c "configure" -c "router bgp 65001" -c "neighbor 192.168.1.3 remote-as 65003"')
      
      # Test remove old description
      remove_cmd = commands.find { |cmd| cmd.include?('no neighbor 192.168.1.2 description OldPeer') }
      expect(remove_cmd).to eq('vtysh -c "configure" -c "router bgp 65001" -c "no neighbor 192.168.1.2 description OldPeer"')
    end
    
    it "formats interface commands with proper context hierarchy" do
      source = "!
interface Ethernet0
 ip address 192.168.1.1/24
exit
!"
      target = "!
interface Ethernet0
 ip address 192.168.1.1/24
 description Primary
exit
!"
      
      commands = Vtysh::Diff.commands(source, target)
      
      # Test adding interface description
      add_cmd = commands.find { |cmd| cmd.include?('description Primary') }
      expect(add_cmd).to eq('vtysh -c "configure" -c "interface Ethernet0" -c "description Primary"')
    end
    
    it "formats combined changes with proper context hierarchy" do
      source = "!
router bgp 65001
 bgp router-id 192.168.1.1
 neighbor 192.168.1.2 remote-as 65002
 neighbor 192.168.1.2 description OldPeer
 address-family ipv4 unicast
  network 10.0.0.0/24
  network 10.0.1.0/24
 exit-address-family
exit
!
interface Ethernet0
 ip address 192.168.1.1/24
exit
! 
"
      target = "!
router bgp 65001
 bgp router-id 192.168.1.1
 neighbor 192.168.1.2 remote-as 65002
 neighbor 192.168.1.2 description UpdatedPeer
 neighbor 192.168.1.3 remote-as 65003
 address-family ipv4 unicast
  network 10.0.0.0/24
  network 10.0.2.0/24
 exit-address-family
exit
!
interface Ethernet0
 ip address 192.168.1.1/24
 description Primary
exit
! 
"
      
      commands = Vtysh::Diff.commands(source, target)
      
      # Test interface description addition
      interface_cmd = commands.find { |cmd| cmd.include?('description Primary') }
      expect(interface_cmd).to eq('vtysh -c "configure" -c "interface Ethernet0" -c "description Primary"')
      
      # Test new neighbor addition
      new_neighbor_cmd = commands.find { |cmd| cmd.include?('neighbor 192.168.1.3') }
      expect(new_neighbor_cmd).to eq('vtysh -c "configure" -c "router bgp 65001" -c "neighbor 192.168.1.3 remote-as 65003"')
      
      # Test neighbor description update
      update_desc_cmd = commands.find { |cmd| cmd.include?('description UpdatedPeer') }
      expect(update_desc_cmd).to eq('vtysh -c "configure" -c "router bgp 65001" -c "neighbor 192.168.1.2 description UpdatedPeer"')
      
      # Test network addition
      add_network_cmd = commands.find { |cmd| cmd.include?('network 10.0.2.0/24') }
      expect(add_network_cmd).to eq('vtysh -c "configure" -c "router bgp 65001" -c "address-family ipv4 unicast" -c "network 10.0.2.0/24"')
      
      # Test network removal
      remove_network_cmd = commands.find { |cmd| cmd.include?('no network 10.0.1.0/24') }
      expect(remove_network_cmd).to eq('vtysh -c "configure" -c "router bgp 65001" -c "address-family ipv4 unicast" -c "no network 10.0.1.0/24"')
    end
  end
end 