__emu() {
  local ACTION="$1"
  local DEVICES DEVICE AVD_NAME IMAGE_TYPE SYSTEM_IMAGE AVDS SELECTED RUNNING RUNNING_AVD

  # If no action provided, show actions menu
  if [ "$ACTION" = "" ]; then
    ACTION=$(echo -e "run\ncreate\nstop\ndelete" | fzf --header="Select action : " --reverse --no-separator --keep-right --border none --cycle --height 70% --info=hidden --header-first --prompt="  " --wrap-sign="" --scheme=path)

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
      if pgrep -f "qemu-system" >/dev/null; then
        RUNNING_AVD=$(ps aux | grep "qemu-system.*-avd" | grep -v grep | sed -n 's/.*-avd \([^ ]*\).*/\1/p' | head -n 1)
        echo "Emulator '$RUNNING_AVD' is already running"
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
      # Get running emulators
      RUNNING=$(ps aux | grep "qemu-system.*-avd" | grep -v grep | sed -n 's/.*-avd \([^ ]*\).*/\1/p')

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
      pkill -f "qemu-system.*-avd $SELECTED"
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

    *)
      echo "Usage: emu [create|run|stop|delete]"
      echo "  emu        - Run an emulator (default)"
      echo "  emu run    - Run an emulator"
      echo "  emu stop   - Stop a running emulator"
      echo "  emu create - Create a new emulator"
      echo "  emu delete - Delete an emulator"
      return 1
      ;;
  esac
}
