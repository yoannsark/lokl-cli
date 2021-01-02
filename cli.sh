#!/bin/sh
#
# lokl-cli: Lokl WordPress site launcher & manager
#
# Allows users to easily spin-up and manage new Lokl WordPress instances
#
# License: The Unlicense, https://unlicense.org
#
# Usage: execute this script from the project root
#
#     run from internet:
#
#     $   \sh -c "$(curl -sSl 'https://lokl.dev/go?v=4')"
#
#     run locally:
#
#     $   sh cli.sh
#
#     to skip the wizard, call the script with vars set:
#
#     lokl_php_ver=php8 \ 
#     lokl_site_name=bananapants \
#     lokl_site_port=4444 \
#     sh cli.sh

lokl_log() {
  echo "$(date '+%H:%M:%S'): $1" >> /tmp/lokldebuglog
} 

set_docker_tag() {
  echo "${lokl_php_ver:?php8}"
}

set_site_name() {
  echo "${lokl_site_name:?''}"
}

set_site_port() {
  echo "${lokl_site_port:?''}"
}

main_menu() {
  clear
  echo ""
  echo "================================================"
  echo "      Lokl launcher & management script         "
  echo ""
  echo "                https://lokl.dev"
  echo ""
  echo "================================================"
  echo "   Press (Ctrl) and (c) keys to exit anytime"
  echo "------------------------------------------------"
  echo ""
  echo "c) Create new Lokl WordPress site"
  echo "m) Manage my existing Lokl sites"
  echo ""
  echo "q) Quit this menu"
  echo ""
  echo ""
  echo "Please type (c), (m) or (q) and the Enter key: "
  echo ""
  read -r main_menu_choice

  if [ "$main_menu_choice" != "${main_menu_choice#[cmq]}" ] ;then
    case $main_menu_choice in
      c|C) create_site_choose_name ;;
      m|M) manage_sites_menu ;;
      q|Q) exit 0 ;;
    esac

  else
    main_menu
  fi
}

test_core_capabilities() {
  clear
  echo ""
  echo "Checking system requirements... "
  echo ""
  test_docker_available
  test_curl_available
}


test_curl_available() {
  if ! command -v curl > /dev/null
  then
      echo "cURL doesn't seem to be installed."
      exit 1
  fi
}

test_docker_available() {
  if ! docker run --rm hello-world > /dev/null 2>&1
  then
     echo "Docker doesn't seem to be running or suitably configured for Lokl"
     exit 1
  fi
}

create_site_choose_name() {
  test_core_capabilities
  clear
  echo ""
  echo "Choose a name for your new Lokl WordPress site. "
  echo ""
  echo "Please use letters, numbers and hyphens         "
  echo ""
  echo "ie, portfolio"
  echo ""
  echo ""
  echo "Type your site name, then the Enter key: "
  echo ""

  read -r create_site_name_choice

  lokl_log "User input desired sitename: $create_site_name_choice"

  LOKL_NAME="$(sanitize_site_name "$create_site_name_choice")"

  lokl_log "Sanitized sitename:: $LOKL_NAME"

  # check name is not empty
  if [ "$LOKL_NAME" = "" ]; then
    if [ "$LOKL_TEST_MODE" ] ;then
      lokl_log "Empty or invalid site name entered"
      # early exit when testing for easier assertion
      exit 1 
    fi

    # re-ask for name entry if input was invalid
    create_site_choose_name
  else
    lokl_log "User input site name: $LOKL_NAME"

    LOKL_PORT="$(get_random_port)"

    lokl_log "Random port number generated: $LOKL_PORT"

    docker run -e N="$LOKL_NAME" -e P="$LOKL_PORT" \
      --name="$LOKL_NAME" -p "$LOKL_PORT":"$LOKL_PORT" \
      -d lokl/lokl:"$LOKL_DOCKER_TAG"

    clear
    echo "Launching your new Lokl WordPress site!"
    echo ""
    echo "Waiting for $LOKL_NAME to be ready"

    # poll until site accessible, print progresss
    attempt_counter=0
    max_attempts=12

    until curl --output /dev/null --silent --head --fail "http://localhost:$LOKL_PORT"; do

        if [ ${attempt_counter} -eq ${max_attempts} ];then
          echo "Timed out waiting for site to come online..."
          exit 1
        fi

        printf '.'
        attempt_counter=$((attempt_counter+1))
        sleep 5
    done

    clear
    echo "Your new Lokl WordPress site, $LOKL_NAME, is ready at:"
    echo ""
    echo "http://localhost:$LOKL_PORT"
    echo ""
    echo "Press any key to manage sites:"

    # return for assertion while testing
    if [ "$LOKL_TEST_MODE" ] ;then
      lokl_log "Returning early for assertion under test runner"
      exit 0 
    fi

    read -r ""
    manage_sites_menu
  fi
}

manage_sites_menu() {
  test_core_capabilities
  clear
  echo ""
  echo "Your Lokl WordPress sites"
  echo ""
  # get all lokl container IDs
  LOKL_CONTAINERS="$(docker ps -a | awk '{ print $1,$2 }' | grep lokl | awk '{print $1 }')"

  # empty flatfile lokl containers cache
  rm -Rf /tmp/lokl_containers_cache/*
  mkdir -p /tmp/lokl_containers_cache/

  SITE_COUNTER=1

  # POSIX compliant way to iterate a list
  OLDIFS="$IFS"
  IFS='
'
  for CONTAINER_ID in $LOKL_CONTAINERS
  do
    CONTAINER_NAME="$(docker inspect --format='{{.Name}}' "$CONTAINER_ID" | sed 's|/||')"
    # get container's exposed port
    CONTAINER_PORT="$(docker inspect --format='{{.NetworkSettings.Ports}}' "$CONTAINER_ID" | \
      sed 's/^[^{]*{\([^{}]*\)}.*/\1/' | awk '{print $2}')"
    # get state
    CONTAINER_STATE="$(docker inspect --format='{{.State.Status}}' "$CONTAINER_ID")"

    # print choices for user
    echo "$SITE_COUNTER)  $CONTAINER_NAME"

    # append choices in cache file named for site counter (brittle internal ID) 
    echo "$CONTAINER_ID,$CONTAINER_NAME,$CONTAINER_PORT,$CONTAINER_STATE" >> /tmp/lokl_containers_cache/$SITE_COUNTER

    SITE_COUNTER=$((SITE_COUNTER+1))
  done
  IFS="$OLDIFS"

  echo ""
  echo "Choose the site you want to manage."
  echo ""
  echo "Type your site's number, then the Enter key: "
  echo ""

  read -r site_to_manage_choice

  # check int selected is in range of available sites
  if [ ! -f "/tmp/lokl_containers_cache/$site_to_manage_choice" ]; then
    echo "Requested site not found, try again"
    manage_sites_menu
  else 
    manage_single_site
  fi
}

start_if_stopped() {
  if [ "$CONTAINER_STATE" != "running" ] ;then
    clear
    echo "$CONTAINER_NAME was stopped, so we're re-launching it"
    echo "before performing your desired action..."
    echo ""

    docker start "$CONTAINER_ID" > /dev/null

    # need to get container port again here
    # get container's exposed port
    CONTAINER_PORT="$(docker inspect --format='{{.NetworkSettings.Ports}}' "$CONTAINER_ID" | \
      sed 's/^[^{]*{\([^{}]*\)}.*/\1/' | awk '{print $2}')"

    echo "Waiting for site to become accessible at http://localhost:$CONTAINER_PORT"

    # poll until site accessible, print progresss
    attempt_counter=0
    max_attempts=12

    # await ready state of webserver after launching
    until curl --output /dev/null --silent --head --fail "http://localhost:$CONTAINER_PORT"; do
        if [ ${attempt_counter} -eq ${max_attempts} ];then
          echo "Timed out waiting for site to come online..."
          exit 1
        fi

        printf '.'
        attempt_counter=$((attempt_counter+1))
        sleep 5
    done
  fi
}

kill_container() {
  clear
  echo "Are you sure you want to force quit $CONTAINER_NAME?"
  echo ""
  echo "Type 'y' for yes:"

  read -r confirm_kill_container

  if [ "$confirm_kill_container" != "y" ] ;then
    manage_single_site
  else
    echo "Stopping $CONTAINER_NAME's server."
    echo ""
    echo "Lokl will attempt to launch it again as you need it"
    echo ""
    docker kill "$CONTAINER_ID" > /dev/null
  fi
}

delete_container() {
  clear
  echo "Are you sure you want to delete $CONTAINER_NAME completely?"
  echo ""
  echo "Type 'y' for yes:"

  read -r confirm_delete_container

  if [ "$confirm_delete_container" != "y" ] ;then
    manage_single_site
  else
    echo "Deleting $CONTAINER_NAME completely."
    echo ""
    docker rm "$CONTAINER_ID" > /dev/null
  fi
}

manage_single_site() {
  clear

  # load lokl container info from cache file
  CONTAINER_INFO=$(cat "/tmp/lokl_containers_cache/$site_to_manage_choice") 
  CONTAINER_ID=$(echo "$CONTAINER_INFO" | cut -f1 -d,)
  CONTAINER_NAME=$(echo "$CONTAINER_INFO" | cut -f2 -d,)
  CONTAINER_PORT=$(echo "$CONTAINER_INFO" | cut -f3 -d,)
  CONTAINER_STATE=$(echo "$CONTAINER_INFO" | cut -f4 -d,)

  # print out details
  echo "Site: $CONTAINER_NAME"
  echo "Status: $CONTAINER_STATE"
  echo ""
  echo "Choose action to perform: "
  echo ""
  echo "o) open site  http://localhost:$CONTAINER_PORT"
  echo "a) open WordPress admin  /wp-admin"
  echo "p) open phpMyAdmin  /phpmyadmin"
  echo "s) SSH into container"
  echo "t) take backup of site files and database"
  echo "l) follow server error logs"

  if [ "$CONTAINER_STATE" = "running" ] ;then
    echo "k) kill (force quit) site's server"
  fi

  if [ "$CONTAINER_STATE" != "running" ] ;then
    echo "d) delete server and site completely"
  fi

  echo ""
  echo "m) Back to manage sites menu"
  echo "q) Quit this menu"
  echo ""
  read -r site_action_choice

  if [ "$site_action_choice" != "${site_action_choice#[oapstlkdmq]}" ] ;then
    case $site_action_choice in
      o|O) open_site_in_browser ;;
      a|A) open_wordpress_admin ;;
      p|P) open_phpmyadmin ;;
      s|S) ssh_into_container ;;
      t|T) take_site_backup ;;
      l|L) follow_error_logs ;;
      m|M) manage_sites_menu ;;
      k|K) kill_container ;;
      d|D) delete_container ;;
      q|Q) exit 0 ;;
    esac

  else
    manage_single_site
  fi
}

# take DB and files backup of site
take_site_backup() {
  start_if_stopped
  clear
  echo "Generating backup file in container..."
  echo ""
  docker exec -it "$CONTAINER_ID" /backup_site.sh
  echo "Saving backup to host computer in path:"
  echo ""
  echo "/tmp/${CONTAINER_NAME}_SITE_BACKUP.tar.gz"
  echo ""
  docker cp "$CONTAINER_ID:/tmp/${CONTAINER_NAME}_SITE_BACKUP.tar.gz" \
    "/tmp/${CONTAINER_NAME}_SITE_BACKUP.tar.gz"

  # ensure file was generated
  if [ ! -f "/tmp/${CONTAINER_NAME}_SITE_BACKUP.tar.gz" ]; then
    echo "Failed to save backup, try again"
    exit 1
  else 
    echo "Backup complete"
    echo ""
    exit 0
  fi
}

# shell connect to container using Docker
ssh_into_container() {
  start_if_stopped
  clear
  echo "Connecting to $CONTAINER_NAME via SSH"
  echo ""
  docker exec -it "$CONTAINER_ID" /bin/sh
}

follow_error_logs() {
  start_if_stopped
  clear
  echo "Following error logs for $CONTAINER_NAME:"
  echo ""
  docker logs -f "$CONTAINER_ID"
}

# open site in default browser
open_site_in_browser() {
  start_if_stopped

  SITE_URL="http://localhost:$CONTAINER_PORT"

  if command -v xdg-open > /dev/null; then
    clear
    echo "Opening $SITE_URL in your browser."
    xdg-open "$SITE_URL"
  elif command -v gnome-open > /dev/null; then
    clear
    echo "Opening $SITE_URL in your browser."
    gnome-open "$SITE_URL"
  elif open -Ra "safari" ; then
    clear
    echo "Opening $SITE_URL in Safari."
    open -a safari "$SITE_URL"
  else
    echo "Couldn't detect the web browser to use."
    echo ""
    echo "Please manually open this URL in your browser:"
    echo ""
    echo "$SITE_URL"
  fi
}

open_wordpress_admin() {
  start_if_stopped

  SITE_URL="http://localhost:$CONTAINER_PORT/wp-admin/"

  if command -v xdg-open > /dev/null; then
    clear
    echo "Opening $SITE_URL in your browser."
    xdg-open "$SITE_URL"
  elif command -v gnome-open > /dev/null; then
    clear
    echo "Opening $SITE_URL in your browser."
    gnome-open "$SITE_URL"
  elif open -Ra "safari" ; then
    clear
    echo "Opening $SITE_URL in Safari."
    open -a safari "$SITE_URL"
  else
    echo "Couldn't detect the web browser to use."
    echo ""
    echo "Please manually open this URL in your browser:"
    echo ""
    echo "$SITE_URL"
  fi
}

open_phpmyadmin() {
  start_if_stopped

  SITE_URL="http://localhost:$CONTAINER_PORT/phpmyadmin/"

  if command -v xdg-open > /dev/null; then
    clear
    echo "Opening $SITE_URL in your browser."
    xdg-open "$SITE_URL"
  elif command -v gnome-open > /dev/null; then
    clear
    echo "Opening $SITE_URL in your browser."
    gnome-open "$SITE_URL"
  elif open -Ra "safari" ; then
    clear
    echo "Opening $SITE_URL in Safari."
    open -a safari "$SITE_URL"
  else
    echo "Couldn't detect the web browser to use."
    echo ""
    echo "Please manually open this URL in your browser:"
    echo ""
    echo "$SITE_URL"
  fi
}

# get all lokl container ports and find another within 4000-5000 range
get_available_container_port() {
  echo ""
  # get all lokl container IDs
  LOKL_CONTAINERS="$(docker ps -a | awk '{ print $1,$2 }' | grep lokl | awk '{print $1 }')"

  # POSIX compliant way to iterate a list
  OLDIFS="$IFS"
  IFS='
'
  for CONTAINER_ID in $LOKL_CONTAINERS
  do
    # get container's exposed port
    CONTAINER_PORT="$(docker inspect --format='{{.NetworkSettings.Ports}}' "$CONTAINER_ID" | \
      sed 's/^[^{]*{\([^{}]*\)}.*/\1/' | awk '{print $2}')"

    echo "$SITE_COUNTER)  http://localhost:$CONTAINER_PORT"

    SITE_COUNTER=$((SITE_COUNTER+1))
  done
  IFS="$OLDIFS"

  echo "Available container port:"
}

get_random_port() {
    random_port="$(awk -v min=4000 -v max=5000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}')"
    # echo value to stdout to be used in cmd substitution
    echo "$random_port"
}


sanitize_site_name() {
  USER_SITE_NAME_CHOICE="$1"

  # strip all non-alpha characters from string, converts to lowercase
  # trims all hyphens
  # trim to 100 chars if over
  echo "$USER_SITE_NAME_CHOICE" | tr -cd '[:alnum:]-' | \
    tr '[:upper:]' '[:lower:]' | sed 's/--//g' | sed 's/^-//' | sed 's/-$//' | \
    cut -c1-100
}

# if running tests, export var to use as flag within functions
# TODO: could put this back in spec_helper, but may annoy shellcheck
if [ "${__SOURCED__}" ] ;then
  lokl_log "### LOKL TEST MODE ENABLED ###"
  export LOKL_TEST_MODE=1
fi

# allow testing without entering menu, using shellspec's var
${__SOURCED__:+return}

LOKL_DOCKER_TAG="$(set_docker_tag)"
LOKL_NAME="$(set_site_name)"
LOKL_PORT="$(set_site_port)"

# skip menu if minimum required arguments are set
if [ "${LOKL_NAME}" ] ;then
  lokl_log "Skipping wizard"
  lokl_log "Site Name Argument Passed: $LOKL_NAME"
  lokl_log "Site Port Argument Passed: $LOKL_PORT"
  lokl_log "Docker Tag Argument Passed: $LOKL_DOCKER_TAG"

  # TODO: create_site_function with argument
  exit 1
else
  main_menu
fi


exit 0
