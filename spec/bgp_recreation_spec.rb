require "spec_helper"
require 'vtysh'

RSpec.describe "BGP recreation (router-id change)" do
  # Generic SONiC FRR configs — old config with one router-id, new with different
  let(:source) do
    <<~FRR
      !
      frr version 8.5.1
      frr defaults traditional
      hostname switch-a
      log syslog informational
      no service integrated-vtysh-config
      !
      password zebra
      enable password zebra
      !
      router bgp 65100
       bgp router-id 10.0.0.1
       bgp disable-ebgp-connected-route-check
       bgp bestpath as-path multipath-relax
       no bgp network import-check
       timers bgp 3 9
       neighbor PEERS peer-group
       neighbor PEERS remote-as 65200
       neighbor 198.51.100.1 remote-as 64500
       neighbor 198.51.100.1 local-as 14000
       bgp listen range 10.10.0.0/16 peer-group PEERS
       !
       address-family ipv4 unicast
        network 203.0.113.0/24
        neighbor PEERS route-map PEERS_IN in
        neighbor 198.51.100.1 route-map UPSTREAM_IN in
        neighbor 198.51.100.1 route-map ANNOUNCE_OUT out
        maximum-paths 64
       exit-address-family
      exit
      !
      ip prefix-list UPSTREAM_ONLY seq 5 permit 0.0.0.0/0
      ip prefix-list ANNOUNCE_OUT seq 10 permit 203.0.113.0/24 le 32
      !
      route-map UPSTREAM_IN permit 10
       match ip address prefix-list UPSTREAM_ONLY
      exit
      !
      route-map UPSTREAM_IN deny 20
      exit
      !
      route-map ANNOUNCE_OUT permit 100
       match ip address prefix-list ANNOUNCE_OUT
      exit
      !
      route-map PEERS_IN permit 10
       match ip address prefix-list PEERS_IN
      exit
      !
      ip nht resolve-via-default
      !
      ip protocol bgp route-map RM_SET_SRC
      !
      end
    FRR
  end

  let(:target) do
    <<~FRR
      !
      frr version 8.5.1
      frr defaults traditional
      hostname switch-a-dc1
      log syslog informational
      no service integrated-vtysh-config
      !
      password zebra
      enable password zebra
      router bgp 65100
       bgp router-id 198.51.100.2
       bgp disable-ebgp-connected-route-check
       bgp bestpath as-path multipath-relax
       no bgp network import-check
       timers bgp 3 9
       neighbor PEERS peer-group
       neighbor PEERS remote-as 65200
       neighbor HA peer-group
       neighbor HA remote-as 65300
       neighbor 198.51.100.1 remote-as 64500
       neighbor 198.51.100.1 local-as 14000
       neighbor 198.51.100.1 ttl-security hops 1
       neighbor 198.51.100.1 advertisement-interval 0
       neighbor 198.51.100.1 timers connect 5
       bgp listen range 10.10.0.0/16 peer-group PEERS
       bgp listen range 172.16.0.0/12 peer-group HA
       !
       address-family ipv4 unicast
        network 203.0.113.0/24
        network 198.51.100.0/24
        neighbor PEERS route-map PEERS_IN in
        neighbor HA route-map HA_IN in
        neighbor 198.51.100.1 remove-private-AS
        neighbor 198.51.100.1 route-map UPSTREAM_IN in
        neighbor 198.51.100.1 route-map ANNOUNCE_OUT out
        maximum-paths 64
       exit-address-family
       !
       address-family ipv6 unicast
        maximum-paths 64
       exit-address-family
      exit
      !
      ip prefix-list UPSTREAM_ONLY seq 5 permit 0.0.0.0/0
      ip prefix-list ANNOUNCE_OUT seq 10 permit 203.0.113.0/24 le 32
      ip prefix-list ANNOUNCE_OUT seq 11 permit 198.51.100.0/24 le 32
      ip prefix-list HA seq 10 permit 172.16.0.3/32 le 32
      ip prefix-list PEERS_IN seq 5 permit 10.128.0.0/9 le 32
      ip prefix-list PEERS_IN seq 10 permit 198.51.100.0/24 le 32
      !
      route-map RM_SET_SRC permit 10
       set src 198.51.100.2
      exit
      !
      route-map UPSTREAM_IN permit 10
       match ip address prefix-list UPSTREAM_ONLY
      exit
      !
      route-map UPSTREAM_IN deny 20
      exit
      !
      route-map ANNOUNCE_OUT permit 100
       match ip address prefix-list ANNOUNCE_OUT
      exit
      !
      route-map PEERS_IN permit 10
       match ip address prefix-list PEERS_IN
      exit
      !
      route-map HA_IN permit 10
       match ip address prefix-list HA
      exit
      !
      ip nht resolve-via-default
      !
      ip protocol bgp route-map RM_SET_SRC
      !
      end
    FRR
  end

  let(:commands) { Vtysh::Diff.commands(source, target) }

  it "generates commands" do
    expect(commands).not_to be_empty
  end

  it "removes BGP block before recreating it" do
    removal_idx = commands.index { |c| c.include?('no router bgp') }
    first_add_idx = commands.index { |c| c.include?('router bgp') && !c.include?('no router bgp') }
    expect(removal_idx).not_to be_nil, "Expected 'no router bgp' command"
    expect(first_add_idx).not_to be_nil, "Expected 'router bgp' creation command"
    expect(removal_idx).to be < first_add_idx,
      "BGP removal (index #{removal_idx}) must come before creation (index #{first_add_idx})"
  end

  it "does not duplicate context as command (no router bgp inside router bgp)" do
    bad = commands.select { |c|
      parts = c.scan(/-c "([^"]+)"/).flatten
      parts.count { |p| p == "router bgp 65100" } > 1
    }
    expect(bad).to be_empty, "Commands with duplicate 'router bgp' context:\n#{bad.join("\n")}"
  end

  it "does not duplicate address-family as command inside address-family context" do
    bad = commands.select { |c|
      parts = c.scan(/-c "([^"]+)"/).flatten
      parts.count { |p| p.start_with?("address-family") } > 1
    }
    expect(bad).to be_empty, "Commands with duplicate address-family:\n#{bad.join("\n")}"
  end

  it "includes complete neighbor arguments (remote-as and local-as have values)" do
    neighbor_cmds = commands.select { |c| c.include?("neighbor") }
    truncated = neighbor_cmds.select { |c|
      c =~ /(?:remote-as|local-as)\s*"/ || c =~ /(?:remote-as|local-as)\s*$/
    }
    expect(truncated).to be_empty, "Truncated neighbor commands:\n#{truncated.join("\n")}"
  end

  it "sets the new router-id" do
    router_id_cmd = commands.find { |c| c.include?("bgp router-id") && !c.include?("no ") }
    expect(router_id_cmd).not_to be_nil
    expect(router_id_cmd).to include("198.51.100.2")
    expect(router_id_cmd).not_to include("10.0.0.1")
  end

  it "adds new prefix-lists" do
    expect(commands.any? { |c| c.include?("ip prefix-list HA") }).to be true
    expect(commands.any? { |c| c.include?("ip prefix-list PEERS_IN seq 5") }).to be true
  end

  it "adds new route-map" do
    expect(commands.any? { |c| c.include?("route-map HA_IN permit 10") }).to be true
  end

  it "produces valid vtysh commands (each starts with vtysh -c)" do
    commands.each do |cmd|
      expect(cmd).to start_with('vtysh -c "configure"'),
        "Invalid command format: #{cmd}"
    end
  end

  context "when configs are identical" do
    it "produces no commands" do
      expect(Vtysh::Diff.commands(source, source)).to be_empty
    end
  end

  context "when only BGP block is removed" do
    let(:target_no_bgp) { "!\nhostname switch-a\n!\nend\n" }

    it "produces only removal command" do
      cmds = Vtysh::Diff.commands(source, target_no_bgp)
      bgp_removal = cmds.select { |c| c.include?("no router bgp") }
      expect(bgp_removal).not_to be_empty
    end
  end
end
