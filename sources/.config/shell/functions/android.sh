__emu() {
  local ACTION="$1"
  local DEVICES DEVICE AVD_NAME IMAGE_TYPE SYSTEM_IMAGE AVDS SELECTED RUNNING RUNNING_AVD

  # If no action provided, show actions menu
  if [ "$ACTION" = "" ]; then
    ACTION=$(echo -e "run\ncreate\nstop\ndelete\nforward\nuninstall" | fzf --header="Select action : " --reverse --no-separator --keep-right --border none --cycle --height 70% --info=hidden --header-first --prompt="  " --wrap-sign="" --scheme=path)

    if [ "$ACTION" = "" ]; then
      echo "No action selected"
      return 0
    fi
  fi

  case "$ACTION" in
    create)
      # Get devices
      DEVICES=$(avdmanager list device 2>/dev/null | grep "id:" | sed 's/.*id: \([0-9]*\) or "\([^"]*\)".*/\2/')

      # Select device
      DEVICE=$(echo "$DEVICES" | fzf --header="Select device type : " --reverse --no-separator --keep-right --border none --cycle --height 70% --info=hidden --header-first --prompt="  " --wrap-sign="" --scheme=path)

      if [ "$DEVICE" = "" ]; then
        echo "No device selected"
        return 0
      fi

      # Prompt name
      read -p "Enter emulator name : " AVD_NAME
      printf "\033[1A\033[2K"

      if [ "$AVD_NAME" = "" ]; then
        echo "No name provided"
        return 1
      fi

      # Check if emulator exists
      if emulator -list-avds | grep -q "^$AVD_NAME$"; then
        echo "Emulator with name '$AVD_NAME' already exists"
        return 1
      fi

      # Select image type
      IMAGE_TYPE=$(echo -e "google_apis\ngoogle_apis_playstore" | fzf --header="Select image type: " --reverse --no-separator --keep-right --border none --cycle --height 70% --info=hidden --header-first --prompt="  " --wrap-sign="" --scheme=path)

      if [ "$IMAGE_TYPE" = "" ]; then
        echo "No image type selected"
        return 0
      fi

      SYSTEM_IMAGE="system-images;android-34;$IMAGE_TYPE;x86_64"

      echo "Creating emulator with:"
      echo "   Name: $AVD_NAME"
      echo "   Device: $DEVICE"
      echo "   System Image: $SYSTEM_IMAGE"
      echo ""

      avdmanager create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" -d "$DEVICE" >/dev/null 2>&1

      if [ $? -eq 0 ]; then
        echo "Emulator '$AVD_NAME' created successfully !"
        echo "Run it with : emu run"
      else
        echo "Failed to create emulator"
        return 1
      fi
      ;;

    run)
      # Check for running emulator
      RUNNING=$(adb devices 2>/dev/null | grep "emulator" | awk '{print $1}')
      if [ "$RUNNING" != "" ]; then
        echo "Emulator already running: $RUNNING"
        return 0
      fi

      # List AVDs
      AVDS=$(emulator -list-avds)

      if [ "$AVDS" = "" ]; then
        echo "No emulators found"
        return 1
      fi

      # Select emulator
      SELECTED=$(echo "$AVDS" | fzf --header="Select an emulator to run : " --reverse --no-separator --keep-right --border none --cycle --height 70% --info=hidden --header-first --prompt="  " --wrap-sign="" --scheme=path)

      if [ "$SELECTED" = "" ]; then
        echo "No emulator selected"
        return 1
      fi

      # Start emulator
      echo "Start emulator $SELECTED :"
      echo ""
      emulator -avd "$SELECTED"
      ;;

    stop)
      # Get running emulators via adb
      RUNNING=$(adb devices 2>/dev/null | grep "emulator" | awk '{print $1}')

      if [ "$RUNNING" = "" ]; then
        echo "No emulator is running"
        return 0
      fi

      # Select emulator
      SELECTED=$(echo "$RUNNING" | fzf --header="Select an emulator to stop : " --reverse --no-separator --keep-right --border none --cycle --height 70% --info=hidden --header-first --prompt="  " --wrap-sign="" --scheme=path)

      if [ "$SELECTED" = "" ]; then
        echo "No emulator selected"
        return 0
      fi

      # Stop emulator
      adb -s "$SELECTED" emu kill
      if [ $? -eq 0 ]; then
        echo "Emulator '$SELECTED' stopped"
      else
        echo "Failed to stop emulator '$SELECTED'"
        return 1
      fi
      ;;

    delete)
      # List AVDs
      AVDS=$(emulator -list-avds)

      if [ "$AVDS" = "" ]; then
        echo "No emulators found"
        return 1
      fi

      # Select emulator
      SELECTED=$(echo "$AVDS" | fzf --header="Select an emulator to delete : " --reverse --no-separator --keep-right --border none --cycle --height 70% --info=hidden --header-first --prompt="  " --wrap-sign="" --scheme=path)

      if [ "$SELECTED" = "" ]; then
        echo "No emulator selected"
        return 0
      fi

      # Delete emulator
      avdmanager delete avd -n "$SELECTED" >/dev/null 2>&1
      if [ $? -eq 0 ]; then
        echo "Emulator '$SELECTED' deleted successfully"
      else
        echo "Failed to delete emulator '$SELECTED'"
        return 1
      fi
      ;;

    forward)
      # Check for running devices
      RUNNING=$(adb devices 2>/dev/null | grep -v "List" | grep "device$" | awk '{print $1}')

      if [ "$RUNNING" = "" ]; then
        echo "No device connected"
        return 1
      fi

      # List listening ports with process name and full command
      # Exclude system processes, emulator internals, and adb
      local PORTS
      PORTS=$(lsof -iTCP -sTCP:LISTEN -nP 2>/dev/null | awk 'NR>1 {split($9,a,":"); port=a[length(a)]; pid=$2; name=$1; cmd=""; "ps -p " pid " -o args= 2>/dev/null" | getline cmd; if (!seen[port]++ && name !~ /qemu|netsimd|adb|rapportd|ControlCe|java/) printf "%-6s %-12s %s\n", port, name, cmd}')

      if [ "$PORTS" = "" ]; then
        echo "No listening ports found"
        return 1
      fi

      # Show already forwarded ports
      local FORWARDED
      FORWARDED=$(adb reverse --list 2>/dev/null)
      if [ "$FORWARDED" != "" ]; then
        echo "Already forwarded:"
        echo "$FORWARDED"
        echo ""
      fi

      # Select ports to forward
      local SELECTED_PORTS
      SELECTED_PORTS=$(echo "$PORTS" | fzf --multi --header="Select ports to forward (TAB to multi-select) : " --reverse --no-separator --keep-right --border none --cycle --height 70% --info=hidden --header-first --prompt="  " --wrap-sign="" --scheme=path)

      if [ "$SELECTED_PORTS" = "" ]; then
        echo "No ports selected"
        return 0
      fi

      # Forward selected ports
      echo "$SELECTED_PORTS" | while read -r line; do
        local PORT
        PORT=$(echo "$line" | awk '{print $1}')
        adb reverse tcp:"$PORT" tcp:"$PORT" && echo "Forwarded port $PORT"
      done
      ;;

    uninstall)
      # Check for running devices
      RUNNING=$(adb devices 2>/dev/null | grep -v "List" | grep "device$" | awk '{print $1}')

      if [ "$RUNNING" = "" ]; then
        echo "No device connected"
        return 1
      fi

      # List third-party packages
      local PACKAGES
      PACKAGES=$(adb shell pm list packages -3 2>/dev/null | sed 's/package://' | sort)

      if [ "$PACKAGES" = "" ]; then
        echo "No apps installed"
        return 1
      fi

      # Select apps to uninstall
      local SELECTED_APPS
      SELECTED_APPS=$(echo "$PACKAGES" | fzf --multi --header="Select apps to uninstall (TAB to multi-select) : " --reverse --no-separator --keep-right --border none --cycle --height 70% --info=hidden --header-first --prompt="  " --wrap-sign="" --scheme=path)

      if [ "$SELECTED_APPS" = "" ]; then
        echo "No apps selected"
        return 0
      fi

      # Uninstall selected apps
      echo "$SELECTED_APPS" | while read -r pkg; do
        adb uninstall "$pkg" && echo "Uninstalled $pkg"
      done
      ;;

    *)
      echo "Usage: emu [create|run|stop|delete|forward|uninstall]"
      echo "  emu           - Show actions menu"
      echo "  emu run       - Run an emulator"
      echo "  emu stop      - Stop a running emulator"
      echo "  emu create    - Create a new emulator"
      echo "  emu delete    - Delete an emulator"
      echo "  emu forward   - Forward dev ports"
      echo "  emu uninstall - Uninstall apps from device"
      return 1
      ;;
  esac
}
