#!/bin/sh

# fetch github repo data: issues, pull requests, wiki, ...

# fetch all data except git data
# git data is trivial to fetch with "git clone --mirror"



#owner=NixOS # permission denied
owner=milahu

repo=nixpkgs



github_token="$GITHUB_TOKEN"
if [ -z "$github_token" ]; then
  echo "error: no GITHUB_TOKEN"
  echo "this script requires a github access token for github.com/$owner/$repo with the scopes: repo, admin:org"
  exit 1
fi



# list user migrations

# repeated migration requests start new migrations
# so we check for existing migrations first

echo "listing migration of github.com/$owner/$repo"

while true; do
  migrations_list="$(
    curl -L \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $github_token" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      https://api.github.com/user/migrations
  )"
  if [ "$(echo "$migrations_list" | jq -r .message)" = "Server Error" ]; then
    echo "failed to list migrations -> retrying"
    sleep 10
    continue
  fi
  break
done
echo "$migrations_list" > migrations_list.json

#echo "migrations_list:"; echo "$migrations_list"
# print migrations_list in YAML format
echo "$migrations_list" | jq -r 'map("- migration:\n  id: \(.id)\n  state: \(.state)\n  repos: \(.repositories | map(.full_name))") | .[]'

migration_id_list="$(
  echo "$migrations_list" | jq -r 'map(select(.repositories | map(.full_name) | index("'"$owner/$repo"'"))) | map(.id) | .[]'
)"
echo "migration_id_list:"; echo "$migration_id_list"

migration_id=$(echo "$migration_id_list" | sort -n | tail -n1)



if [ -z "$migration_id" ]; then

  # start user migration
  echo "starting migration of github.com/$owner/$repo"

  migration_start="$(
    curl -L \
      -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $github_token" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      https://api.github.com/user/migrations \
      -d '{
        "repositories":["'"$owner/$repo"'"],
        "lock_repositories":true,
        "exclude_metadata":false,
        "exclude_git_data":true,
        "exclude_attachments":false,
        "exclude_releases":true,
        "exclude_owner_projects":true
      }'
  )"

  echo "$migration_start" >migration_start.json

  if [ "$(echo "$migrations_list" | jq -r .message)" = "Validation Failed" ]; then
    echo "error: failed to start migration"
    exit 1
  fi

  migration_id=$(jq -r .id <<<"$migration_start")

  if [ -z "$migration_id" ]; then
    echo "error: no migration_id"
    echo "migration_start:"; echo "$migration_start"
    exit 1
  fi

fi

echo "ok: migration_id = $migration_id"



# wait for migration to complete
while true; do

  # get user migration status

  migration_status="$(
    curl -L \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $github_token" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/user/migrations/$migration_id"
  )"

  echo "$migration_status" > migration_status.json
  #echo "migration_status:"; echo "$migration_status"

  migration_state="$(echo "$migration_status" | jq -r .state)"
  case "$migration_state" in
    exported)
      echo "migration is complete"
      break
    ;;
    *)
      echo "migration state is '$migration_state' -> waiting"
      sleep 10
      continue
    ;;
  esac

done

created_at=$(echo "$migration_status" | jq -r .created_at)
echo "migration was created at $created_at"

archive_url=$(echo "$migration_status" | jq -r .archive_url)
echo "migration archive url: $archive_url"

archive_path="migration-$migration_id.tar.gz"

# FIXME continue download of existing partial file
if ! [ -e "$archive_path" ]; then
  echo "writing $archive_path"
  curl -L \
    -o "$archive_path" \
    -H "Accept: application/gzip" \
    -H "Authorization: Bearer $github_token" \
    "$archive_url"
fi
