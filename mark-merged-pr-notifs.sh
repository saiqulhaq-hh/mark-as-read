#!/bin/bash

# Mark merged PR notifications as read (with parallel processing)
# Usage: ./mark-merged-pr-notifs.sh [--max-parallel N] [--repo OWNER/REPO]

set -euo pipefail

# Configuration
MAX_PARALLEL=${1:-5}  # Default to 5 parallel jobs
FILTER_REPO=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --max-parallel)
            MAX_PARALLEL="$2"
            shift 2
            ;;
        --repo)
            FILTER_REPO="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# Function to print colored output
log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Function to mark single notification as read
mark_notification_read() {
    local notification_id=$1
    local repo=$2
    local pr_number=$3

    # Check if PR is merged
    if gh pr view "$pr_number" -R "$repo" --json mergedAt --jq '.mergedAt' 2>/dev/null | grep -q .; then
        # PR is merged, mark notification as read
        if gh api \
            --method PATCH \
            "notifications/threads/${notification_id}" \
            -f read=true 2>/dev/null; then
            log_success "Marked #$pr_number in $repo as read (merged)"
            return 0
        else
            log_error "Failed to mark notification for #$pr_number in $repo"
            return 1
        fi
    else
        # PR is not merged, skip
        log_warning "Skipped #$pr_number in $repo (not merged)"
        return 0
    fi
}

export -f mark_notification_read log_info log_success log_error log_warning

# Main logic
main() {
    log_info "Fetching unread notifications..."

    # Get unread notifications (filter by repo if specified)
    if [ -n "$FILTER_REPO" ]; then
        notifications=$(gh api notifications \
            --jq ".[] | select(.repository.full_name == \"$FILTER_REPO\") | .id" 2>/dev/null || true)
    else
        notifications=$(gh api notifications \
            --jq '.[] | .id' 2>/dev/null || true)
    fi

    if [ -z "$notifications" ]; then
        log_success "No unread notifications found!"
        exit 0
    fi

    # Count notifications
    notif_count=$(echo "$notifications" | wc -l)
    log_info "Found $notif_count unread notifications"

    # Get detailed notification data (need repo and PR number for each)
    log_info "Analyzing notifications (checking merge status)..."

    if [ -n "$FILTER_REPO" ]; then
        notifications_with_details=$(gh api notifications \
            --jq ".[] | select(.subject.type == \"PullRequest\" and .repository.full_name == \"$FILTER_REPO\") | \"\(.id)|\(.repository.full_name)|\(.subject.url | split(\"/\") | .[-1])\"" 2>/dev/null || true)
    else
        notifications_with_details=$(gh api notifications \
            --jq '.[] | select(.subject.type == "PullRequest") | "\(.id)|\(.repository.full_name)|\(.subject.url | split("/") | .[-1])"' 2>/dev/null || true)
    fi

    if [ -z "$notifications_with_details" ]; then
        log_warning "No PR notifications found in unread notifications"
        exit 0
    fi

    # Process notifications in parallel using xargs
    echo "$notifications_with_details" | \
        xargs -P "$MAX_PARALLEL" -I {} bash -c '
            IFS="|" read -r notif_id repo pr_num <<< "{}"
            mark_notification_read "$notif_id" "$repo" "$pr_num"
        '

    log_success "Done! All merged PR notifications have been marked as read."
}

main "$@"

