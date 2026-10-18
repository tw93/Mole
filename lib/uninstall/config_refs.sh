#!/bin/bash
# Read-only hints for configuration paths that refer to this completed removal.
# Never print configuration contents: they can contain credentials on the same line.
_uninstall_scan_configuration_references() {
    run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" /usr/bin/perl - "$HOME" "$@" << 'PERL'
use strict;
use warnings;
use Cwd qw(realpath);
use Fcntl qw(O_RDONLY O_NOFOLLOW S_ISREG);
my $home = shift @ARGV;
my $physical_home = realpath($home);
exit 0 unless defined $physical_home;
my @needles;
for my $path (@ARGV) {
    next unless $path =~ m{^/} && length($path) > 1;
    next if -e $path || -l $path;
    push @needles, $path;
    if (index($path, "$home/") == 0) {
        my $relative = substr($path, length($home) + 1);
        push @needles, "~/$relative", '$HOME/' . $relative, '${HOME}/' . $relative;
    }
}
exit 0 unless @needles;
my @configs = qw(.zshrc .zprofile .zshenv .bashrc .bash_profile .profile
    .config/fish/config.fish
    .claude/settings.json .claude.json .codex/hooks.json .codex/config.toml
    .cursor/hooks.json .cursor/mcp.json .gemini/settings.json);
for my $relative (@configs) {
    my $path = "$home/$relative";
    my @before = lstat($path);
    next unless @before && S_ISREG($before[2]) && $before[7] <= 1048576;
    my $resolved = realpath($path);
    next unless defined($resolved) && index($resolved, "$physical_home/") == 0;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or next;
    my @opened = stat($file);
    next unless @opened && S_ISREG($opened[2]) && $opened[0] == $before[0] && $opened[1] == $before[1];
    my $text = '';
    my $read = read($file, $text, 1048577);
    my @after = stat($file);
    close $file;
    next unless defined($read) && $read == $before[7] && $read <= 1048576 && index($text, "\0") < 0;
    next unless @after && $after[7] == $before[7] && $after[9] == $before[9];
    my $number = 0;
    for my $line (split /\n/, $text) {
        ++$number;
        $line =~ s{\\/}{/}g;
        for my $needle (@needles) {
            if ($line =~ /(?<![A-Za-z0-9_.\/-])\Q$needle\E(?=$|[\/\s"'\)\],;}])/ ) {
                my $display = "~/$relative";
                $display =~ s/([\x00-\x1f\x7f])/sprintf('\\x%02x', ord($1))/ge;
                print "$display:$number\n";
                last;
            }
        }
    }
}
PERL
}

uninstall_configuration_references() {
    [[ $# -gt 0 && -x /usr/bin/perl ]] || return 0
    local mentions="" rc=0
    mentions=$(_uninstall_scan_configuration_references "$@") || rc=$?
    mole_rc_signal "$rc" && return "$rc"
    [[ $rc -eq 0 && -n "$mentions" ]] || return 0
    printf '\nConfiguration references kept (review manually):\n%s\n' "$mentions"
}

# shellcheck disable=SC2154  # Results and plans belong to batch_uninstall_applications.
_batch_report_configuration_references() {
    is_uninstall_dry_run && return 0
    [[ ${#success_items[@]} -gt 0 ]] || return 0
    local -a paths=("${success_items[@]}")
    local detail name app id total encoded remainder path
    for detail in "${app_details[@]}"; do
        IFS='|' read -r name app id total encoded remainder <<< "$detail"
        mole_identity_in_list "$app" "${success_items[@]}" || continue
        while IFS= read -r path; do
            [[ -n "$path" && ! -e "$path" && ! -L "$path" ]] || continue
            paths+=("$path")
        done < <(decode_file_list "$encoded" "$name")
    done
    uninstall_configuration_references "${paths[@]}"
}
