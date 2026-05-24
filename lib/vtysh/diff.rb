module Vtysh
  class Diff
    def self.commands(source, target)
      source_cmds = parse_config(source)
      target_cmds = parse_config(target)

      if needs_bgp_recreation?(source_cmds, target_cmds)
        bgp_commands = handle_bgp_recreation(source_cmds, target_cmds)
        non_bgp_commands = handle_non_bgp_changes(source_cmds, target_cmds, skip_bgp_blocks: true)
        bgp_commands + non_bgp_commands
      else
        handle_non_bgp_changes(source_cmds, target_cmds) +
          handle_incremental_bgp_changes(source_cmds, target_cmds)
      end
    end

    private

    def self.handle_non_bgp_changes(source_cmds, target_cmds, skip_bgp_blocks: false)
      commands = []

      # Removals (non-BGP, plus top-level BGP block removals when not recreating)
      (source_cmds - target_cmds).each do |cmd|
        next if inside_bgp?(cmd) && !cmd[:command].start_with?("router bgp")
        next if skip_bgp_blocks && cmd[:command].start_with?("router bgp")
        if is_block_command(cmd[:command])
          commands << format_removal_command(cmd)
        elsif cmd[:depth] > 0
          next if block_being_removed?(cmd, source_cmds, target_cmds)
          commands << format_context_command("no #{cmd[:command]}", cmd[:context])
        else
          commands << vtysh_cmd("no #{cmd[:command]}")
        end
      end

      # Non-BGP additions
      (target_cmds - source_cmds).each do |cmd|
        next if inside_bgp?(cmd)
        if is_block_command(cmd[:command])
          commands << vtysh_cmd(cmd[:command])
        elsif cmd[:depth] > 0
          commands << format_context_command(cmd[:command], cmd[:context])
        else
          commands << vtysh_cmd(cmd[:command])
        end
      end

      reorder_non_bgp(commands)
    end

    def self.handle_incremental_bgp_changes(source_cmds, target_cmds)
      commands = []

      # BGP removals
      (source_cmds - target_cmds).each do |cmd|
        next unless inside_bgp?(cmd)
        next if cmd[:command].start_with?("router bgp") # don't remove the block itself
        next if block_being_removed?(cmd, source_cmds, target_cmds)
        commands << format_context_command("no #{cmd[:command]}", cmd[:context])
      end

      # BGP additions
      (target_cmds - source_cmds).each do |cmd|
        next unless inside_bgp?(cmd)
        next if cmd[:command].start_with?("router bgp")
        commands << format_context_command(cmd[:command], cmd[:context])
      end

      reorder_bgp(commands)
    end

    def self.handle_bgp_recreation(source_cmds, target_cmds)
      source_asns = source_cmds.select { |c| c[:command].start_with?("router bgp") }.map { |c| c[:command].split[2] }
      target_asns = target_cmds.select { |c| c[:command].start_with?("router bgp") }.map { |c| c[:command].split[2] }

      commands = []

      (source_asns & target_asns).each do |asn|
        bgp_ctx = "router bgp #{asn}"

        # Step 1: Remove the old BGP block
        commands << vtysh_cmd("no #{bgp_ctx}")

        # Step 2: Create the new BGP block
        commands << vtysh_cmd(bgp_ctx)

        # Step 3: Add main BGP commands (not inside address-family)
        target_bgp = target_cmds.select { |c|
          c[:depth] > 0 &&
          c[:context].include?(bgp_ctx) &&
          !c[:context].any? { |ctx| ctx.start_with?("address-family") } &&
          !is_block_command(c[:command])  # skip block commands (router bgp, address-family)
        }

        target_bgp.sort_by { |c| bgp_command_priority(c[:command]) }.each do |cmd|
          commands << vtysh_cmd(bgp_ctx, cmd[:command])
        end

        # Step 4: Add address-family blocks
        af_contexts = target_cmds.select { |c|
          c[:command].start_with?("address-family") && c[:context].include?(bgp_ctx)
        }.map { |c| c[:command] }.uniq

        af_contexts.each do |af|
          commands << vtysh_cmd(bgp_ctx, af)

          af_cmds = target_cmds.select { |c|
            c[:depth] > 0 &&
            c[:context].include?(bgp_ctx) &&
            c[:context].include?(af) &&
            c[:command] != af  # skip the address-family command itself
          }

          af_cmds.each do |cmd|
            commands << vtysh_cmd(bgp_ctx, af, cmd[:command])
          end
        end
      end

      commands
    end

    # --- Helpers ---

    def self.inside_bgp?(cmd)
      cmd[:context].any? { |ctx| ctx.start_with?("router bgp") } ||
        cmd[:command].start_with?("router bgp")
    end

    def self.block_being_removed?(cmd, source_cmds, target_cmds)
      removals = source_cmds - target_cmds
      cmd[:context].any? { |ctx|
        is_block_command(ctx) && removals.any? { |r| r[:command] == ctx }
      }
    end

    def self.needs_bgp_recreation?(source_cmds, target_cmds)
      source_asns = source_cmds.select { |c| c[:command].start_with?("router bgp") }.map { |c| c[:command].split[2] }
      target_asns = target_cmds.select { |c| c[:command].start_with?("router bgp") }.map { |c| c[:command].split[2] }

      return false if source_asns != target_asns || source_asns.empty?

      source_asns.any? do |asn|
        src_rid = source_cmds.find { |c| c[:command].include?("bgp router-id") && c[:context].any? { |ctx| ctx.include?("router bgp #{asn}") } }
        tgt_rid = target_cmds.find { |c| c[:command].include?("bgp router-id") && c[:context].any? { |ctx| ctx.include?("router bgp #{asn}") } }
        src_rid && tgt_rid && src_rid[:command] != tgt_rid[:command]
      end
    end

    def self.bgp_command_priority(cmd)
      case
      when cmd.include?('bgp router-id') then 1
      when cmd =~ /neighbor \S+ peer-group$/ then 2
      when cmd.include?('remote-as') then 3
      when cmd =~ /neighbor \S+ local-as/ then 4
      when cmd.include?('bgp listen range') then 5
      else 6
      end
    end

    def self.reorder_non_bgp(commands)
      prefix_lists = commands.select { |c| c.include?("ip prefix-list") }
      route_maps = commands.select { |c| c.include?("route-map") && !c.include?("no ") }
      removals = commands.select { |c| c.include?("no ") } - prefix_lists
      rest = commands - prefix_lists - route_maps - removals

      (prefix_lists + route_maps + rest + removals).uniq
    end

    def self.reorder_bgp(commands)
      peer_groups = commands.select { |c| c =~ /neighbor \S+ peer-group"$/ && !c.include?("no ") }
      remote_as = commands.select { |c| c.include?("remote-as") && !c.include?("no ") }
      listen_range = commands.select { |c| c.include?("bgp listen range") && !c.include?("no ") }
      removals = commands.select { |c| c.include?("no ") }
      rest = commands - peer_groups - remote_as - listen_range - removals

      (peer_groups + remote_as + listen_range + rest + removals).uniq
    end

    # --- Parsing ---

    def self.parse_config(config)
      commands = []
      context_stack = []

      config.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#', '!')

        if line =~ /^exit(-address-family|-vrf)?$/
          context_stack.pop unless context_stack.empty?
        elsif line == 'end'
          context_stack = []
        elsif is_block_command(line)
          context_stack << line
          commands << { command: line, context: context_stack.dup, depth: context_stack.size }
        else
          commands << { command: line, context: context_stack.dup, depth: context_stack.size }
        end
      end

      commands
    end

    def self.is_block_command(cmd)
      cmd.start_with?('router ', 'interface ', 'route-map ', 'vrf ', 'address-family ')
    end

    # --- Formatting ---

    def self.vtysh_cmd(*parts)
      args = ["configure"] + parts
      "vtysh " + args.map { |p| "-c \"#{p}\"" }.join(" ")
    end

    def self.format_removal_command(cmd)
      vtysh_cmd("no #{cmd[:command]}")
    end

    def self.format_context_command(command, context)
      parts = context.map { |ctx| ctx }
      vtysh_cmd(*parts, command)
    end
  end
end
