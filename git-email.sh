#!/usr/bin/env bash
# Requirements: bash 4+

# Default values
USE_FILTERS=true
INCLUDE_NAME=true
INCLUDE_FORK=true
INCLUDE_PRIVATE=true
UPDATE=false
KEEP_DOWNLOADS=false

GREEN='\033[0;32m'
BOLD_WHITE='\033[1;37m'
NO_COLOR='\033[0m'
OVERWRITE='\e[1A\e[K'

set -o errexit   # abort on nonzero exitstatus
set -o nounset   # abort on unbound variable
set -o pipefail  # don't hide errors within pipes

usage() {
	echo -e "\nUsage: $0 (option) [repo url|local repo|GitHub Org/User]"
	echo -e '\t-h, --help\t\tPrint this help page'
	echo -e '\t-o, --output=FILE\tFile to save the output into'
	echo -e '\t-f,--filter=FILE\tFilter out emails containing this filter'
	echo -e '\t-r, --raw\t\tNo filter no banner'
	echo -e '\t--exclude-name\t\tExclude authors'\''s name'
	echo -e '\t--exclude-fork\t\tExclude forked repos from the scan'
	echo -e '\t--exclude-private\tExclude private repos from the scan'
	echo -e '\t-k, --keep\t\tKeep downloaded .git(s) after the scan'
	echo -e '\t-u, --update\t\tUpdate existing .git(s) before the scan'
	echo -e '\t--no-color\t\tDo not use colors\n'
}

# Usage: error ERROR_MSG
error() {
	echo "Error: $*"
	usage
	exit 1
}

parse_args() {
	read -r OWNER SCAN_NAME USER_FILTERS OUTPUT_FILE TARGET <<< ''
	while (( "$#" )); do
		case "$1" in
			--help|-h) usage; exit;;
			--output=*) OUTPUT_FILE="${1#*=}";;
			--output |-o ) OUTPUT_FILE=$2; shift;;
			--filter=*) USER_FILTERS+=" -e ${1#*=}";;
			--filter |-f ) USER_FILTERS+=" -e ${2}"; shift;;
			--raw |-r ) USE_FILTERS=false;;
			--exclude-name ) INCLUDE_NAME=false;;
			--exclude-fork ) INCLUDE_FORK=false;;
			--exclude-private ) INCLUDE_PRIVATE=false;;
			--keep |-k ) KEEP_DOWNLOADS=true;;
			--update |-u ) UPDATE=true;;
			--no-color ) read -r NO_COLOR BOLD_WHITE GREEN <<< '';;
			*)
				TARGET="$1"
		esac
		shift
	done

	if [ -n "$TARGET" ] && [ ${#REPO_LIST[@]} -le 0 ]; then

		# Check if target is a local dir
		if [ -d "$TARGET" ]; then
			SCAN_NAME="$(basename "$TARGET")"
			get_repo_list_local "$TARGET"

		# Check if target is a remote git repo
		elif repo_exist_not_empty "$TARGET"; then
			local _scan_name
			_scan_name="${TARGET#*.*/}"
			SCAN_NAME="${_scan_name%.git}"
			REPO_LIST=("$TARGET")

		# Check if URI is a GitHub repo
		elif [[ "$TARGET" =~ ^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+$ ]]; then
			if repo_exist_not_empty "https://github.com/${TARGET}"; then
				SCAN_NAME="$TARGET"
				REPO_LIST=("https://github.com/${TARGET}")
			else
				error "repository empty"
			fi

		# Otherwise
		# Check if it is a GitHub Org/User
		elif gh_owner_exist "$TARGET"; then
			if gh_owner_has_repo "$TARGET"; then
				SCAN_NAME="$TARGET"
				get_gh_owner_repo_list "$TARGET"
				if [ ${#REPO_LIST[@]} -le 0 ] && [ $INCLUDE_FORK = 'false' ]; then
					error 'owner has no accessible repository matching criterias'
				fi
			else
				error 'owner has no accessible repository'
			fi
		fi

		if [ ${#REPO_LIST[@]} -le 0 ]; then
			error "target not found or empty: $TARGET"
		fi

	elif [ -z "$TARGET" ]; then
		error 'no target provided'
	fi
}

clean() {
	echo -e "[${GREEN}i${NO_COLOR}] - Cleaning up..."
	[ $KEEP_DOWNLOADS = 'false' ] && rm -rf "${TEMP_DIR:?}"
	echo -e "${OVERWRITE}[${GREEN}✓${NO_COLOR}] - Cleaning up"
}

on_error() {
	result=$?
	clean
	exit $result
}

repo_exist_not_empty() {
	git ls-remote --quiet --exit-code "$1" >/dev/null 2>&1
	return $?
}

gh_owner_exist() {
	gh api "users/$1" --silent 2> /dev/null
	return $?
}

gh_owner_has_repo(){
	if [ "$(gh api "users/$1" --jq '.public_repos')" -gt 0 ]; then
		return 0
	else
		return 1
	fi
}

is_gh_fork() {
	if [ "$(gh repo view "$1" --json isFork --jq '.isFork')" = 'true' ]; then
		return 0
	else
		return 1
	fi
}

# Usage: get_email DIR
# Output: $authors
get_authors() {
	authors=''
	while read -r line && [ -n "$line" ]; do
		authors+="\n$line"
	done <<< "$(git -C "$1" log --format='%ae - "%an"' --all --quiet)"
	authors="$(echo -e "$authors")"
}

# Usage: clone REPO_URL DESTINATION_DIR
clone() {
	local ret_error
	ret_error=1

	if [ -d "$2" ]; then
		if [ $UPDATE = 'true' ]; then
			echo -n ' Updating...'
			if git -C "$2" pull --quiet &> /dev/null; then
				ret_error=0
			else
				echo -n ' Failed. Downloading...'

				# Attempt to clone the repo in a temp dir
				if repo_exist_not_empty "$1"; then
					if git clone --bare --quiet "$1" "_$2"; then
						rm -rf "${2:?}" && \
						mv --force "_$2" "$2" && \
						ret_error=0
					else
						error "repository out of reach: $1"
					fi
				else
					ret_error=0
					echo -n ' Repo empty, skipping...'
				fi
			fi
		else
			ret_error=0
		fi
	else
		echo -n ' Downloading...'
		if repo_exist_not_empty "$1"; then
			if git clone --bare --quiet "$1" "$2" --quiet; then
				ret_error=0
			else
				error "repository out of reach: $1"
			fi
		else
			ret_error=0
			echo -n ' Repo empty, skipping...'
		fi
	fi

	return $ret_error
}

# Usage: scan_repo_list REPO_ARRAY
# Output: $total_authors
scan_repo_list() {
	local len_repo_list counter repo clone_dir
	local -n repo_list=$1
	total_authors=''
	len_repo_list="${#repo_list[@]}"
	counter=1
	authors=''
	for url in "${repo_list[@]}"; do
		if [ "$url" = '*/.git' ]; then
			repo="$(basename "${url%%/.git}")"
		else
			repo="$(basename "${url%%.git}")"
		fi

		echo -ne "\n[${GREEN}${counter}/${len_repo_list}${NO_COLOR}] - ${BOLD_WHITE}${repo}${NO_COLOR}:"

		# If no download then no temp dir is required
		if [ "${url%://*}" = 'file' ] && [ ! $UPDATE = 'true' ]; then
			clone_dir="${url#*://}"
		else
			clone_dir="${TEMP_DIR}/${repo}"
			clone "$url" "$clone_dir"
		fi

		if [ -d "$clone_dir" ]; then
			echo -n ' Parsing...'
			get_authors "$clone_dir"
		fi

		total_authors+="$authors"
		counter=$((counter + 1))

		echo -ne " ${GREEN}✓${NO_COLOR}"
	done
}

# Usage: output_results AUTHORS
output_results() {
	local author_count output
	author_count="$(wc -l <<< "$1")"

	if [ "$author_count" -le '1' ]; then
		echo -ne "\n[${GREEN}i${NO_COLOR}] - No email matching criterias found.\n"
	else
		if [ -n "$OUTPUT_FILE" ]; then
			echo -ne "\n[${GREEN}i${NO_COLOR}] - Saving to ${BOLD_WHITE}${OUTPUT_FILE}${NO_COLOR}...\n"
			output=''
			if [ "$USE_FILTERS" = 'true' ]; then
				output+='---------------------------------------\n\n'
				output+="Scan of ${SCAN_NAME}\n"
				output+='\n---------------------------------------\n\n'
			fi
			output+="$1"
			echo -e "$output" > "${OUTPUT_FILE:?}"
		else
			echo -e "\n${1}\n"
		fi
	fi
}

# Usage: get_repo_list_local DIR
# Output: $REPO_LIST
get_repo_list_local() {
	local local_git_list git_path_absolute

	# Add all .git(s) to list
	local_git_list="$(find "$1" -maxdepth 3 -type f -name 'description' ! -size 0)"
	if [ -n "$local_git_list" ]; then
		while read -r git_path; do
			git_path_absolute="$(realpath "${git_path%%/description}")"
			if repo_exist_not_empty "$git_path_absolute"; then
				REPO_LIST+=("file://${git_path_absolute}")
			else
				error "directory is not a Git repository: $(basename "$git_path_absolute")"
			fi
		done <<< "$local_git_list"
	else
		error 'empty directory'
	fi
}

# Usage: get_gh_owner_repo_list OWNER
# Output: $REPO_LIST
get_gh_owner_repo_list() {
	local owner_type repo_url

	if [ "$(gh api "users/$1" --jq '.type' 2> /dev/null)" = 'Organization' ]; then
		owner_type='orgs'
	else
		owner_type='users'
	fi

	while read -r repo_url && [ -n "$repo_url" ]; do
		REPO_LIST+=("$repo_url")
	done <<< "$(gh api "$owner_type/$1/repos" --paginate --jq ".[] | select(.fork == false or $INCLUDE_FORK) | select(.private == false or $INCLUDE_PRIVATE) | .clone_url")"
}

# Usage: filter AUTHORS
# Output: $authors
filter() {
	local FILTERS
	filtered_list=''

	if [ $USE_FILTERS = 'true' ]; then
		# Remove protected and bot emails
		FILTERS="'^$' -e @users.noreply.github.com -e actions@github.com${USER_FILTERS}"
	else
		# Remove empty lines
		FILTERS="'^$'${USER_FILTERS}"
	fi

	# Sort unique lines
	filtered_list="$(sort --unique --ignore-case <<< "$1")"

	# Remove names
	if [ $INCLUDE_NAME != 'true' ]; then
		filtered_list="$(awk '{print $1}' <<< "$filtered_list")"
	fi

	# Apply filters
	filtered_list="$(grep -Fve $FILTERS <<< "$filtered_list")"

	# Check emails from forked repos
	if [ $INCLUDE_FORK = 'true' ] && [ -n "$OWNER" ] && is_gh_fork "$OWNER/$repo"; then
		filtered_list="$(awk '{print $0, "(fork)"}' <<< "$filtered_list")"
	fi

	# Concatenate authors with the same email address
	filtered_list=$(awk '{
		first_word=$1;
		second_word=$2;

		if (!(first_word in lines)) {
			lines[first_word] = $0
		} else {
			sub(first_word, "", $0);
			if (second_word == "-") {
				sub(" " second_word " ", "", $0)
			}
			lines[first_word] = lines[first_word] " | " $0
		}
	}
	END {
		for (word in lines) {
			print lines[word]
		}
	}' <<< "$filtered_list")

	# Sort unique lines
	filtered_list="$(sort --unique --ignore-case <<< "$filtered_list")"
}

# Parse arguments
REPO_LIST=()
parse_args "$@"

# Handle download dir
if [ $KEEP_DOWNLOADS = 'true' ]; then
	TEMP_DIR="$SCAN_NAME"
	[ ! -d "$TEMP_DIR" ] && mkdir -p "${TEMP_DIR:?}"
else
	TEMP_DIR="$(mktemp --directory --quiet --suffix=.git-email)"
fi

echo -e '\n---------------------------------------\n'
echo -e "Starting scan of ${BOLD_WHITE}${SCAN_NAME}${NO_COLOR}"
echo -e '\n---------------------------------------'

# Handle errors and exit
trap on_error ERR INT

scan_repo_list REPO_LIST
filter "$total_authors"
output_results "$filtered_list"
clean
echo