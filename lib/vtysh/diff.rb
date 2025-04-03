module Vtysh
  class Diff
    def self.commands(source, target)
      # Parse configurations into flat commands
      source_cmds = parse_config(source)
      target_cmds = parse_config(target)
      
      # Generate commands to transform source to target
      commands = []
      
      # Special case for router-id changes
      if needs_bgp_recreation?(source_cmds, target_cmds)
        commands.concat(handle_bgp_recreation(source_cmds, target_cmds))
      else
        # Handle removals first (items in source but not in target)
        (source_cmds - target_cmds).each do |cmd|
          if is_block_command(cmd[:command])
            # For block commands like "router bgp X", we need to remove the whole block
            commands << format_removal_command(cmd)
            
            # Skip commands inside this block - they'll be removed automatically
            if cmd[:command].start_with?("router bgp")
              # We need to specifically exclude commands inside this removed BGP block
              # to avoid generating individual "no" commands for them
              asn = cmd[:command].split[2]
              # Don't generate commands for items in this block
            end
          elsif cmd[:depth] > 0
            # Check if we're removing a command inside a block that's already being removed
            block_being_removed = false
            cmd[:context].each do |ctx|
              # Check if any of the contexts is a block that's being removed
              if source_cmds.any? { |s| s[:command] == ctx && (source_cmds - target_cmds).include?(s) }
                block_being_removed = true
                break
              end
            end
            
            # Only generate a command if not inside a block that's being removed
            unless block_being_removed
              # For commands inside blocks, we need to provide the proper context
              commands << format_context_command("no #{cmd[:command]}", cmd[:context])
            end
          else
            # For top-level commands
            commands << "vtysh -c \"configure\" -c \"no #{cmd[:command]}\""
          end
        end
        
        # Handle additions (items in target but not in source)
        (target_cmds - source_cmds).each do |cmd|
          if is_block_command(cmd[:command]) 
            # For block commands like "router bgp X", include the block creation
            commands << "vtysh -c \"configure\" -c \"#{cmd[:command]}\""
          elsif cmd[:depth] > 0
            # For commands inside blocks, we need to provide the proper context
            commands << format_context_command(cmd[:command], cmd[:context])
          else
            # For top-level commands
            commands << "vtysh -c \"configure\" -c \"#{cmd[:command]}\""
          end
        end
      end
      
      # Sort commands and apply dependency-based reordering
      reorder_commands(commands.uniq)
    end
    
    private
    
    # New improved command ordering function that ensures the proper order for BGP-related commands
    def self.reorder_commands(commands)
      # First extract all the commands that need to be properly ordered
      all_peer_group_cmds = commands.select { |cmd| cmd.include?("neighbor") && cmd.include?("peer-group") && !cmd.include?("no ") }
      all_remote_as_cmds = commands.select { |cmd| cmd.include?("remote-as") }
      all_listen_range_cmds = commands.select { |cmd| cmd.include?("bgp listen range") }
      
      # Need to remove these from commands for proper reordering
      clean_commands = commands - all_peer_group_cmds - all_remote_as_cmds - all_listen_range_cmds
      
      # Apply correct ordering for all commands
      final_commands = []
      
      # Handle prefix-lists first (always)
      prefix_list_cmds = clean_commands.select { |cmd| cmd.include?("ip prefix-list") }
      final_commands.concat(prefix_list_cmds)
      
      # Handle route-map definitions second
      route_map_cmds = clean_commands.select { |cmd| cmd.include?("route-map") && !cmd.include?("neighbor") && !cmd.include?("no ") }
      final_commands.concat(route_map_cmds)
      
      # Include router bgp blocks
      bgp_block_cmds = clean_commands.select { |cmd| cmd.include?("router bgp") && !cmd.include?("no ") && cmd.count("\"") <= 6 }
      final_commands.concat(bgp_block_cmds)
      
      # Now add peer-group commands first
      all_peer_group_cmds.sort.each do |cmd|
        final_commands << cmd
      end
      
      # Then add remote-as commands
      all_remote_as_cmds.sort.each do |cmd|
        final_commands << cmd
      end
      
      # Then add listen-range commands
      all_listen_range_cmds.sort.each do |cmd|
        final_commands << cmd
      end
      
      # Add all remaining commands except removals
      remaining_cmds = clean_commands.select { |cmd| !cmd.include?("no ") }
      remaining_cmds -= final_commands
      final_commands.concat(remaining_cmds)
      
      # Add removal commands at the end
      removal_cmds = clean_commands.select { |cmd| cmd.include?("no ") }
      final_commands.concat(removal_cmds)
      
      # Return unique commands with duplicates removed
      final_commands.uniq
    end
    
    def self.needs_bgp_recreation?(source_cmds, target_cmds)
      # Get BGP ASNs from both configs
      source_bgp = source_cmds.select { |cmd| cmd[:command].start_with?("router bgp") }
      target_bgp = target_cmds.select { |cmd| cmd[:command].start_with?("router bgp") }
      
      # Check if we have the same ASN in both
      source_asns = source_bgp.map { |cmd| cmd[:command].split[2] }
      target_asns = target_bgp.map { |cmd| cmd[:command].split[2] }
      
      # If ASNs don't match, no need for special handling
      return false if source_asns != target_asns || source_asns.empty?
      
      # For each ASN that appears in both, check for router-id changes
      source_asns.each do |asn|
        # Find router-id in source
        src_bgp_cmds = source_cmds.select { |cmd| 
          cmd[:depth] > 0 && 
          cmd[:context].any? { |ctx| ctx.start_with?("router bgp #{asn}") } &&
          cmd[:command].include?("bgp router-id")
        }
        
        # Find router-id in target
        tgt_bgp_cmds = target_cmds.select { |cmd| 
          cmd[:depth] > 0 && 
          cmd[:context].any? { |ctx| ctx.start_with?("router bgp #{asn}") } &&
          cmd[:command].include?("bgp router-id")
        }
        
        # If both have router-id and they're different, return true
        if !src_bgp_cmds.empty? && !tgt_bgp_cmds.empty? && 
           src_bgp_cmds.first[:command] != tgt_bgp_cmds.first[:command]
          return true
        end
      end
      
      false
    end
    
    def self.handle_bgp_recreation(source_cmds, target_cmds)
      commands = []
      
      # Get BGP ASNs
      source_bgp = source_cmds.select { |cmd| cmd[:command].start_with?("router bgp") }
      target_bgp = target_cmds.select { |cmd| cmd[:command].start_with?("router bgp") }
      
      source_asns = source_bgp.map { |cmd| cmd[:command].split[2] }
      target_asns = target_bgp.map { |cmd| cmd[:command].split[2] }
      
      # For each ASN, recreate the BGP block
      (source_asns & target_asns).each do |asn|
        # Remove the BGP block
        commands << "vtysh -c \"configure\" -c \"no router bgp #{asn}\""
        
        # Get the commands for this BGP block in the target config
        target_bgp_block = target_cmds.select { |cmd| 
          cmd[:depth] > 0 && cmd[:context].any? { |ctx| ctx.start_with?("router bgp #{asn}") }
        }
        
        # Add the BGP block itself
        commands << "vtysh -c \"configure\" -c \"router bgp #{asn}\""
        
        # Add commands within the BGP block
        bgp_main_cmds = target_bgp_block.select { |cmd| 
          !cmd[:context].any? { |ctx| ctx.start_with?("address-family") }
        }
        
        # Sort commands - router-id first, then peer-groups, then remote-as, etc.
        bgp_main_cmds.sort_by! { |cmd| bgp_command_priority(cmd[:command]) }
        
        # Add the main BGP commands
        bgp_main_cmds.each do |cmd|
          commands << "vtysh -c \"configure\" -c \"router bgp #{asn}\" -c \"#{cmd[:command]}\""
        end
        
        # Add address-family blocks and their commands
        af_contexts = target_bgp_block.map { |cmd| 
          cmd[:context].find { |ctx| ctx.start_with?("address-family") }
        }.compact.uniq
        
        af_contexts.each do |af_ctx|
          # Add the address-family context
          commands << "vtysh -c \"configure\" -c \"router bgp #{asn}\" -c \"#{af_ctx}\""
          
          # Add commands in this address-family
          af_cmds = target_bgp_block.select { |cmd| cmd[:context].include?(af_ctx) }
          af_cmds.each do |cmd|
            commands << "vtysh -c \"configure\" -c \"router bgp #{asn}\" -c \"#{af_ctx}\" -c \"#{cmd[:command]}\""
          end
        end
      end
      
      commands
    end
    
    def self.bgp_command_priority(cmd)
      # Define priority for BGP commands (lower number = higher priority)
      if cmd.include?('bgp router-id')
        return 1  # router-id should be first
      elsif cmd.include?('neighbor') && cmd.include?('peer-group') && !cmd.include?(' route-map ')
        return 2  # peer-group definitions second
      elsif cmd.include?('remote-as')
        return 3  # remote-as commands next
      elsif cmd.include?('bgp listen range')
        return 4  # bgp listen range commands after
      else
        return 5  # other commands last
      end
    end
    
    def self.parse_config(config)
      lines = config.split("\n").map(&:strip)
      commands = []
      context_stack = []
      
      lines.each do |line|
        next if line.empty? || line.start_with?('#', '!')
        
        if line == 'exit' || line == 'exit-vrf' || line == 'exit-address-family'
          # Exit the current context
          context_stack.pop unless context_stack.empty?
        elsif line == 'end'
          # Exit all contexts
          context_stack = []
        elsif is_block_command(line)
          # Start a new context block
          context_stack << line
          commands << { command: line, context: context_stack.dup, depth: context_stack.size }
        else
          # Regular command, may be inside a context
          commands << { command: line, context: context_stack.dup, depth: context_stack.size }
        end
      end
      
      commands
    end
    
    def self.is_block_command(cmd)
      cmd.start_with?('router ', 'interface ', 'route-map ', 'vrf ', 'address-family ')
    end
    
    def self.needs_exit_command(cmd)
      cmd.start_with?('router ', 'interface ', 'vrf ')
    end
    
    def self.format_removal_command(cmd)
      command = cmd[:command]
      
      # For block commands with nested structures
      if command.start_with?('router bgp')
        asn = command.split[2]
        return "vtysh -c \"configure\" -c \"no router bgp #{asn}\""
      elsif command.start_with?('interface')
        iface = command.split[1] 
        return "vtysh -c \"configure\" -c \"no interface #{iface}\""
      elsif command.start_with?('vrf')
        vrf_name = command.split[1]
        return "vtysh -c \"configure\" -c \"no vrf #{vrf_name}\""
      elsif command.start_with?('route-map')
        parts = command.split
        if parts.size >= 4
          return "vtysh -c \"configure\" -c \"no route-map #{parts[1]} #{parts[2]} #{parts[3]}\""
        else
          return "vtysh -c \"configure\" -c \"no #{command}\""
        end
      else
        # Generic block removal
        return "vtysh -c \"configure\" -c \"no #{command}\""
      end
    end
    
    def self.format_context_command(command, context)
      result = "vtysh -c \"configure\""
      
      # Add each context element
      context.each do |ctx|
        if ctx.start_with?('router bgp')
          asn = ctx.split[2]
          result += " -c \"router bgp #{asn}\""
        elsif ctx.start_with?('interface')
          iface = ctx.split[1]
          result += " -c \"interface #{iface}\""
        elsif ctx.start_with?('address-family')
          parts = ctx.split
          if parts.size > 2
            result += " -c \"address-family #{parts[1]} #{parts[2]}\""
          else
            result += " -c \"address-family #{parts[1]}\""
          end
        else
          # Generic context
          result += " -c \"#{ctx}\""
        end
      end
      
      # Add the command itself
      result += " -c \"#{command}\""
      
      result
    end
  end
end 