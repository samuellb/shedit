#!/bin/sh -ue
#
# Copyright (c) 2015 Samuel Lidén Borell <samuel@kodafritt.se>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#

# TODO test with PuTTY
# TODO ability to use shEdit as a pager?
# TODO avoid creating subshells (in getrow[DONE], getchars, readcmd, getmodname)
# TODO might be able to remove echo x|... also with here-documents (see http://mywiki.wooledge.org/BashFAQ/001)
# SKIPPED is $' standard? and can we escape things in it according to the standard? it works in Bash and zsh, but NOT in Dash
# DONE replace `...` with $(...)
# DONE remove x in [ "x$.." = xblabla ], see http://mywiki.wooledge.org/BashPitfalls  #4
# DONE $((...)) can lead to code injection (at least in Bash) -- seems to be ok
# TODO handle Ctrl-Z (restore terminal, then proceed) and fg (refresh editor screen)
# TODO handle bracketed paste (update screen in on go after all changes, and don't autoindent or accept any commands)
# TODO use local variables? is it part of a standard and does it work with bash, zsh, mksh, ksh etc?
# TODO double check the Emacs keys
# TODO filter out control characters and special unicode whitespace characters (is that really needed?) when displaying lines

sheditver=0.0.1

# goals for 0.1.0:
#   [DONE] loading files (requires text input on the status bar)
#   [PARTIALLY DONE] saving files
#   [DONE] crude form of insertion/deletion of lines
#   word navigation
#   [DONE] UTF-8 input support
#
# goals for 0.2.0:
#   search
#   one of:
#    - UTF-8 support (${#} usually returns bytes, but may return characters also in Bash 3)
#            could use  printf %x '$1  to convert from char to hex (or decimal), see http://mywiki.wooledge.org/BashFAQ/071
#            needs to set LC_CTYPE (either to C or UTF-8, which one?)
#   (and perhaps long line handling after this, since that would have to be rewritten if implemented before UTF-8)
#    - deferred line insertion/deletion
#
# goals for 0.3.0
#   the remaining of
#    - UTF-8 support
#    - long line handling
#    - deferred line insertion/deletion
#
# goals for 1.0.0
#   use efficient escape sequences for insertion/deletion of columns/lines
#   Ctrl-Z handling if that's possible
#
# goals for 1.1.0
#   ability to use as a pager
#

# TODO auto-detect those two?
use_bash_read=0 # reacts immediately to SIGWINCH (window resize), unlike when using an external command such as dd or head. BUT can cause Bash to segfault.
use_head=0
bad_input_mode=1
IFS=' '
set +o noclobber

readonly esc="$(printf '\033')"
#readonly esc=$'\033'
#readonly esc=$'\0x1b'
readonly lf="$(printf '\n')"
readonly tab="$(printf '\011')"
readonly del8="$(printf '\010')"
readonly del126="$(printf '\176')"
readonly char7f="$(printf '\177')"
readonly ctrl_a="$(printf '\001')"
readonly ctrl_b="$(printf '\002')"
readonly ctrl_d="$(printf '\004')"
readonly ctrl_e="$(printf '\005')"
readonly ctrl_f="$(printf '\006')"
readonly ctrl_g="$(printf '\007')"
readonly ctrl_h="$(printf '\010')"
readonly ctrl_k="$(printf '\013')"
readonly ctrl_l="$(printf '\014')"
readonly ctrl_n="$(printf '\016')"
readonly ctrl_o="$(printf '\017')"
readonly ctrl_p="$(printf '\020')"
readonly ctrl_r="$(printf '\022')"
readonly ctrl_t="$(printf '\024')"
readonly ctrl_u="$(printf '\025')"
readonly ctrl_v="$(printf '\026')"
readonly ctrl_w="$(printf '\027')"
readonly ctrl_x="$(printf '\030')"
readonly ctrl_y="$(printf '\031')"
# Escape codes that we don't use but we want to filter out
readonly bell="$(printf '\007')"
readonly vertical_tab="$(printf '\013')"
readonly formfeed="$(printf '\014')"
readonly carriage_return="$(printf '\015')"
readonly charset_g1="$(printf '\016')"
readonly charset_g0="$(printf '\017')"
readonly csi="$(printf '\233')"
# TODO more escape codes to filter out?

readonly saved_stty="$(stty -g)"

initialized=0
init() {
    stty -ixon -ixoff -echo -icanon min 1 time 0 && bad_input_mode=0
    
    # Terminal initialization
    printf "\033[?1049h"

    # Reset misc. stuff
    printf "\033[0m\033(B\033[?25h"

    # Disable auto-wrap
    printf "\033[?7l"
    
    # Bracketed paste
    #printf "\033[?2004h"
    
    # Clear screen
    printf "\033[3J" # including scroll back
    printf "\033[2J" # if the above fails
    
    initialized=1
    resized
}

cleanup() {
    # Go to the last line, in case the terminal doesn't restore the screen contents
#    printf '\033['$((rows - 1))';1H\033[2K\n\033[2K'    # XXX create more problems than it solves in other terminal emulators, e.g. tmux
#    printf '\033['$((rows - 3))';1H'    # XXX create more problems than it solves in other terminal emulators, e.g. tmux
#    printf "\033[${rows};1H\n"
#    sleep 0.5  # for debugging
    
    # Enable auto-wrap
    printf "\033[?7h"
    
    # Bracketed paste
    #printf "\033[?2004l"
    
    # Reset misc. stuff
    printf "\033[0m\033(B\033[?25h"
    
    # Terminal de-initialization
    printf "\033[?1049l\015"
    
    stty "$saved_stty"
}

getwinsize() {
    # TODO should try tput cols / tput lines or "tpus lines cols" first
    if [ $bad_input_mode = 0 ]; then
        oldIFS="$IFS"
        IFS='; '
        # FIXME probably not very reliable
        stty -a | while read -r a b c d e f g rest; do
            if [ "$d" = rows ] && [ "$e" -gt 5 ] && [ "$f" = columns ] && [ "$g" -gt 5 ]; then
                echo $e $g
                break
            fi
        done || true
        unset a b c d e f g rest
        IFS="$oldIFS"
    fi
}

# ZSH doesn't seem to do any field splitting on function arguments, but this works
getfirst() { echo $1 | { read a b; echo $a; }; }
getsecond() { echo $1 | { read a b; echo $b; }; }

rows=24
columns=80
resized() {
    winsize=$(getwinsize)
    if [ -n "$winsize" ]; then
        rows=$(getfirst $winsize)
        columns=$(getsecond $winsize)
    fi
    refresh
}

status_error=""
refresh() {
    printf '\033[0m\033[2J\033[1;1H'
    # Display the file contents from current_row
    i=1
    while [ $i -lt $rows ]; do
        # TODO truncate long lines (try $# first, then dd)
        # TODO use a distinct line number for scrolling?
        filerow=$((current_top_row + i - 1))
        if [ $filerow -gt $file_rows ]; then
            row_result=""
        else
            getrow $filerow
        fi
        printf '%s\n' "$row_result"
        i=$((i + 1))
    done
    
    # Refresh status line
    refresh_status
}

update_cursor() {
    screen_row=$((current_row - current_top_row + 1))
    screen_col=$current_col # TODO
    printf '\033['$screen_row';'$screen_col'H'
}

refresh_status() {
    # Display the status line
    # TODO truncate too long filenames and numbers > 9999?
    if [ $file_dirty = 0 ]; then
        dirty=' '
    else
        dirty='\033[1m*\033[0m'
    fi
    if [ -z "$file_filename" ]; then
        filename=" (new file)"
    else
        filename="$file_filename"
    fi
    if [ -n "$status_error" ]; then
        extra="\033[1m$status_error\033[0m"
    elif [ $bad_input_mode = 1 ]; then
        extra="Must press ENTER after keystrokes! ^G:Help"
    else
        extra="Ctrl- X:Exit O:Write R:Read G:Help"
    fi
    # TODO truncate the filename from the left
    #      or just display the basename (but that's an external command!)
    printf "\033[${rows};1H\033[7m\033[2K%s%19.19s | L%4d, C%4d | $extra" "$dirty" "$filename" $current_row $current_col
    
    # Move cursor to the correct row/column
    update_cursor
}

refresh_line() {
    row=$((current_row - current_top_row + 1))
    printf '\033['$row';1H\033[0m\033[2K'
    getrow $current_row
    printf '%s\n' "$row_result"
}

wipe_clean_line() {
    # TODO we should track how many bytes were read and only refresh
    # characters that where actually overwritten.
    trash_text_row=$((trash_row + current_top_row - 1))
    printf '\033['$trash_row';1H\033[0m\033[2K'
    getrow $trash_text_row
    printf '%s\n' "$row_result"
    update_cursor
}

help_screen() {
    printf '\033[0m\033[2J\033[1;1H'
    
    echo ""
    printf "     ----[ shEDit Help ]---- v. %-6s- (C) 2015 Samuel Liden Borell ----\n" "$sheditver"
    if [ $bad_input_mode = 1 ]; then
        echo '     *NOTE* You are in "bad input mode" (due to missing stty command)'
        echo '     You must press ENTER after typing in commands or characters'
    else
        echo ""
        echo "                          Available keyboard commands:"
    fi
    
    cat <<EOF

     +----------------------+----------------------+--------------------+
     |  MAIN COMMANDS       |  NAVIGATING          |  EDITING           |
     +----------------------+----------------------+--------------------+
     |  Ctrl-X Exit         |  Arrow keys to       |  Delete and back-  |
     |  Ctrl-O Write file   |  move single steps   |  space should do   |
     |  Ctrl-R Read file    |                      |  what you expect.  |
     |  Ctrl-W Search       |  Ctrl-arrow keys     |                    |
     |  Ctrl-G This help    |  to step one word    |  Ctrl or Alt       |
     +----------------------+                      |  plus those keys   |
     |                         Home/End moves to   |  delete words.     |
     |  Hint! You can also     start/end of line   |                    |
     |  use Emacs-style                            |  Only ASCII is     |
     |  keyboard commands:     PageUp/PageDown     |  supported so far. |
     |                         moves one screen    |  (maybe UTF-8 in   |
     |  Ctrl-BFPNAED,Alt-BF                        |   the future.)     |
     |                                             |                    |
     +---------------------------------------------+--------------------+
EOF
    
    printf "\033[${rows};1H\033[7m\033[2K Press ENTER to exit help                           http://shedit.kodafritt.se/"

    if [ $bad_input_mode = 1 ]; then
        readcmd | true # because we have an enter key press in the buffer already
    fi
    while true; do
        cmd="$(readcmd)"
        if [ "$cmd" = linefeed -o "$cmd" = esc_esc ]; then
            break
        fi
    done
}

refresh_inputline() {
    printf "\033[${rows};13H\033[0m\033[K%s\033[${rows};%s" "$input_reply" $((12 + col))H
}

readinput() {
    prompt=$1
    printf "\033[${rows};1H\033[7m\033[2K%10s: \033[0m" "$prompt"
    
    input_responded=0
    if [ $bad_input_mode = 1 ]; then
        read input_reply
        # perhaps the user pressed enter directly after the command
        # (which is needed to get a visible prompt in "bad input mode")
        if [ -z "$input_reply" ]; then
            read input_reply
        fi
        input_responded=1
        refresh # screen will have scrolled now!
        # TODO we could avoid refreshing by using the second last row instead!
    else
        input_reply=$2
        col=$((${#input_reply} + 1))
        lastcol=$col
        printf %s "$input_reply"
        while true; do
            cmd="$(readcmd)"
            case "$cmd" in
            ctrl_x|ctrl_c|esc_esc) break;;
            left|ctrl_b)
                if [ $col -gt 1 ]; then
                    col=$((col - 1))
                    printf '\033[1D'
                fi;;
            right|ctrl_f)
                if [ $col -lt $lastcol ]; then
                    col=$((col + 1))
                    printf '\033[1C'
                fi;;
            ctrl_left|alt_b)
                # TODO move one word to the left
                true;;
            ctrl_right|alt_f)
                # TODO move one word to the right
                true;;
            home|ctrl_a)
                if [ $col != 1 ]; then
                    col=1
                    refresh_inputline
                fi;;
            end|ctrl_e)
                if [ $col != $((lastcol)) ]; then
                    col=$((lastcol))
                    refresh_inputline
                fi;;
            linefeed)
                input_responded=1
                break;;
            backspace)
                if [ $col != 1 ]; then
                    strstart $((col - 1)) "$input_reply"
                    start=$str_result
                    strend $col "$input_reply"
                    end=$str_result
                    input_reply="$start$end"

                    col=$((col - 1))
                    lastcol=$((lastcol - 1))

                    refresh_inputline
                fi;;
            delete)
                if [ $col != $lastcol ]; then
                    strstart $col "$input_reply"
                    start=$str_result
                    strend $((col + 1)) "$input_reply"
                    end=$str_result
                    input_reply="$start$end"

                    lastcol=$((lastcol - 1))

                    refresh_inputline
                fi;;
            ctrl_bksp)
                # TODO delete word to the left
                true;;
            ctrl_del|alt_del|alt_d)
                # TODO delete word to the right
                true;;
            tab)
                # TODO tab completion
                true;;
            other*)
                key=${cmd#other }
                keylen=${#key}
                strstart $col "$input_reply"
                start=$str_result
                strend $col "$input_reply"
                end=$str_result
                input_reply="$start$key$end"
                col=$((col + keylen))
                lastcol=$((lastcol + keylen))
                refresh_inputline;;
            esac
        done
        refresh_status
        update_cursor
    fi
}

cmd_help() {
    status_error=""
    help_screen
    refresh
}

newfile() {
    file_filename=""
    file_rows=1
    file_row1=""
    file_dirty=0
    current_top_row=1
    current_row=1
    current_col=1
    current_lastcol=1
    current_linetext=""
    current_linelen=0
    trash_row=1
}

filterrow() {
    s=$fileline
    # FIXME $csi (\233) matches \333 also
    eval 's=${s#*'"$bell"'}; s=${s#*'"$del8"'}; s=${s#*'"$vertical_tab"'}; s=${s#*'"$formfeed"'}; s=${s#*'"$carriage_return"'}; s=${s#*'"$charset_g1"'}; s=${s#*'"$charset_g0"'}; s=${s#*'"$esc"'}; s=${s#*'"$csi"'}'
    if [ "$s" != "$fileline" ]; then
        # TODO
        fileline=FILTERED
    fi
}

loadfile() {
    file_filename=""
    file_rows=0
    file_row1=""
    file_dirty=0
    IFS=''
    # TODO save stderr output here, just like in savefile
    while read -r fileline; do
        file_rows=$((file_rows + 1))
        #printf '%s\n' "line:$fileline"
        filterrow
        setrow $file_rows "$fileline"
    done < "$1" || show_error "failed to read $1"
    IFS=' '
    current_top_row=1
    current_row=1
    current_col=1
    current_lastcol=1
    current_linetext="$file_row1"
    # TODO handle UTF-8 here, ${#xxx} returns the number of bytes in the string (except in Bash 3+)
    current_linelen="${#current_linetext}"
    file_filename="$1"
    trash_row=1
}

dumptext() {
    while [ $i -le $file_rows ]; do
        getrow $i
        printf '%s\n' "$row_result"
        i=$((i + 1))
    done > "$1" || echo " "
}

savefile() {
    filename=$1
    overwrite=$2
    
    if [ $overwrite = 1 ]; then
        set +o noclobber
    else
        set -o noclobber
    fi
    i=1
    ok=0
    save_err=$(dumptext "$filename" 2>&1 || echo .;)
    # Strip script file name
    save_err=${save_err##*:}
    # Only include text before the first newline (excluding the newline)
    read -r save_err <<EOF
$save_err
EOF
    set +o noclobber
    if [ -n "$save_err" ]; then
        return 1
    fi
    
    file_filename=$filename
    return 0
}

getrow() {
    #eval 'printf "%s\n" "${file_row'$1'-}"'
    eval 'row_result="${file_row'$1'-}"'
}

setrow() {
    rowdata="$2"
    eval 'file_row'$1'="$rowdata"'
    unset rowdata
}

show_error() {
    if [ $initialized = 1 ]; then
        status_error="$1"
        refresh_status
    else
        echo "error: $1" >&2
        exit 1
    fi
}

stdin_error() {
    # TODO
    true
    #read a line, then if non-empty call show_error
}

kbd_error() {
    # Perhaps log $1 somehow?
    show_error "Unhandled escape code"
}


if [ $# = 0 ]; then
    # New file
    newfile
elif [ $# = 1 ]; then
    loadfile "$1"
else
    echo "error: more than one filename specified. perhaps you should use '' ?" >&2
    echo "usage: $0 filename" >&2
    exit 2
fi

init
trap cleanup 0
#trap exit INT HUP TERM QUIT
trap cmd_quit INT
trap cmd_forcequit HUP TERM QUIT
trap resized WINCH

check_dirty() {
    if [ $file_dirty = 0 ]; then
        return 0
    else
        # TODO
        return 0
    fi
}

cmd_quit() {
    check_dirty && { cleanup; exit; }
}

cmd_forcequit() {
    # TODO save to some .autosave.shedit file here?
    cleanup
    exit
}

cmd_write() {
    status_error=""
    readinput "Write file" "$file_filename"
    if [ $input_responded = 0 ]; then
        return
    fi
    filename=$input_reply
    
    # Check if the name was changed
    if [ "$filename" != "$file_filename" ]; then
        # Prompt when the name is changed
        # TODO
        overwrite=0
    else
        overwrite=1
    fi
    
    # Save the file
    if ! savefile "$filename" $overwrite; then
        if [ $overwrite = 0  -a  -e "$filename" ]; then
            # Prompt for overwrite
            # TODO
            return
        else
            status_error="Write failed: $save_err"
            refresh_status
            return
        fi
    fi
    file_dirty=0
    refresh_status
}

cmd_read() {
    status_error=""
    readinput "Read file" "$file_filename"
    if [ $input_responded = 1  -a  -n "$input_reply" ]; then
        # TODO should also be able to insert a file into the current buffer also
        loadfile "$input_reply"
        refresh
    fi
}

cmd_search() {
    status_error=""
    # TODO
    status_error="Search not yet working"
    refresh_status
}


scroll_if_needed() {
    if [ $current_row -lt $current_top_row ]; then
         halfpage=$((rows / 2))
         current_top_row=$((current_top_row - halfpage))
         limitvscroll
         return 0
    elif [ $current_row -gt $((current_top_row + rows - 2)) ]; then
         halfpage=$((rows / 2))
         current_top_row=$((current_top_row + halfpage))
         limitvscroll
         return 0
    else
         return 1
    fi
}

scroll_and_refresh() {
    if scroll_if_needed; then
        refresh
    else
        refresh_status  # this should be optional
        #update_cursor
    fi
}

limitvscroll() {
    if [ $current_top_row -gt $((file_rows - rows + 2)) ]; then
        current_top_row=$((file_rows - rows + 2))
    fi
    if [ $current_top_row -lt 1 ]; then
        current_top_row=1
    fi
}

cmd_vscrollmove() {
    old_top_row=$current_top_row
    vmove "$1"
    current_top_row=$(($1 + current_top_row))
    limitvscroll
    if [ $old_top_row != $current_top_row ]; then
        refresh
    else
        refresh_status
    fi
}

linechanged() {
    getrow $current_row
    current_linetext="$row_result"
    current_linelen="${#current_linetext}"
}

vmove() {
    # TODO need to limit the current column when displaying the cursor or the number of it
    current_row=$(($1 + current_row))
    if [ $current_row -gt $file_rows ]; then
        current_row=$file_rows
    fi
    if [ $current_row -lt 1 ]; then
        current_row=1
    fi
    linechanged
    current_col=$current_lastcol
    if [ $current_col -gt $((current_linelen + 1)) ]; then
        current_col=$((current_linelen + 1))
    fi
}

cmd_vmove() {
    vmove $1
    scroll_and_refresh
}

cmd_hmove() {
    current_col=$(($1 + current_col))
    # FIXME utf-8 support
    if [ $current_col -gt $((current_linelen + 1)) ]; then
        if [ $current_row -lt $file_rows ]; then
            vmove 1
            current_col=1
            scroll_and_refresh
        else
            current_col=$((current_linelen + 1))
        fi
    elif [ $current_col -lt 1 ]; then
        if [ $current_row -gt 1 ]; then
            vmove -1
            current_col=$((current_linelen + 1))
            scroll_and_refresh
        else
            current_col=1
        fi
    else
        refresh_status # this should be optional
        #update_cursor
    fi
    current_lastcol=$current_col
}

cmd_home() {
    current_col=1
    current_lastcol=$current_col
    refresh_status # should be optional
}

cmd_end() {
    current_col=$((current_linelen + 1))
    current_lastcol=$current_col
    refresh_status # should be optional
}

cmd_top() {
    current_row=1
    linechanged
    current_col=1
    current_lastcol=1
    if [ $current_top_row != 1 ]; then
        current_top_row=1
        refresh
    else
        refresh_status
    fi
}

cmd_bottom() {
    current_row=$file_rows
    linechanged
    current_col=$((current_linelen + 1))
    current_lastcol=$current_col
    if [ $current_top_row != $((file_rows - rows + 2)) ]; then
        current_top_row=$((file_rows - rows + 2))
        refresh
    else
        refresh_status
    fi
}

cmd_nextword() {
    # TODO
    true
}

cmd_prevword() {
    # TODO
    true
}

str_result=""
strrepeat() {
    strrep_i=$1
    str_result=""
    # TODO could optimize this
    while [ $strrep_i -gt 0 ]; do
        str_result="$str_result$2"
        strrep_i=$((strrep_i - 1))
    done
    unset strrep_i
}

strstart() {
    if [ $1 -lt 2 ]; then
        str_result=""
    elif [ $1 -gt ${#2} ]; then
        str_result="$2"
    else
        strrepeat $((${#2} - $1 + 1)) "?"
        # Patterns in variables aren't supported in zsh
        #str_result="${2%$str_result}"
        eval 'str_result="${2%'$str_result'}"'
    fi
}

strend() {
    if [ $1 -lt 2 ]; then
        str_result="$2"
    elif [ $1 -gt ${#2} ]; then
        str_result=""
    else
        strrepeat $(($1 - 1)) "?"
        #echo "pattern=[$str_result]"
        #str_result="${2#$str_result}"
        eval 'str_result="${2#'$str_result'}"'
    fi
}

#strstart 3 "abcdefg"
#echo "[$str_result]"
#strend 3 "abcdefg"
#echo "[$str_result]"
#read X

deletestr() {
    strstart $1 "$current_linetext"
    start="$str_result"
    strend $2 "$current_linetext"
    end="$str_result"
    current_linetext="$start$end"
    setrow $current_row "$current_linetext"
    # TODO handle UTF-8 here
    current_linelen=$((current_linelen - $2 + $1))
    if [ $3 = backward ]; then
        current_col=$1
        current_lastcol=$current_col
    fi
}

insertline() {
    rownum=$1
    contents=$2
    
    # TODO need some way of defer insertion of lines for efficiency.
    #      perhaps only update the lines that are visible on the screen, and then extend the set of updated lines when other parts of the file becomes visible
    # alternatively, all lines could be given a sequential number, with next/prev variables. there should also be a pointer table of perhaps every 10 lines for fast lookups
    i=$file_rows
    while [ $i -ge $rownum ]; do
        getrow $i
        setrow $((i + 1)) "$row_result"
        i=$((i - 1))
    done
    file_rows=$((file_rows + 1))
    
    setrow $rownum "$2"
}

deleteline() {
    rownum=$1  # this is the line after the line to delete
    contents=$2
    
    # TODO just like with insertline, we need some way of defer delete of lines for efficiency.
    i=$((rownum + 2))
    while [ $i -le $file_rows ]; do
        getrow $i
        setrow $((i - 1)) "$row_result"
        i=$((i + 1))
    done
    eval 'unset line_'$file_rows
    file_rows=$((file_rows - 1))
    
    setrow $rownum "$2"
}

cmd_del_charright() {
    if [ $current_col = $((current_linelen + 1)) ]; then
        if [ $current_row != $file_rows ]; then
            getrow $current_row
            start=$row_result
            getrow $((current_row + 1))
            end=$row_result
            deleteline $current_row "$start$end"
            current_linetext="$start$end"
            current_linelen=${#current_linetext}
            scroll_if_needed || true
            # TODO this is inefficient. should use some kind of scrolling instead
            refresh
        fi
    else
        deletestr $((current_col)) $((current_col + 1)) forward
        refresh_line $current_row
        update_cursor
    fi
}

cmd_del_charleft() {
    if [ $current_col = 1 ]; then
        if [ $current_row != 1 ]; then
            getrow $((current_row - 1))
            start=$row_result
            getrow $current_row
            end=$row_result
            current_row=$((current_row - 1))
            deleteline $current_row "$start$end"
            current_linetext="$start$end"
            current_linelen=${#current_linetext}
            current_col=$((${#start} + 1))
            current_lastcol=$current_col
            scroll_if_needed || true
            # TODO this is inefficient. should use some kind of scrolling instead
            refresh
        fi
    else
        deletestr $((current_col - 1)) $((current_col)) backward
        refresh_line $current_row
        update_cursor
    fi
}

cmd_del_wordright() {
    # TODO
    true
}

cmd_del_wordleft() {
    # TODO
    true
}

insert_str() {
    inslen=${#1}
    col=$current_col # FIXME should be the byte index!
    strstart $col "$current_linetext"
    start="$str_result"
    strend $col "$current_linetext"
    end="$str_result"
    current_linetext="$start$1$end"
    setrow $current_row "$current_linetext"
    # TODO handle UTF-8 here
    current_linelen=$((current_linelen + inslen))
    current_col=$((current_col + inslen))
    current_lastcol=$current_col
}

cmd_insert_tab() {
    # TODO switch between tabs as spaces and tabs as tabs
    #if [ $tab_as_spaces = 1 ]; then
        col=$((current_col - 1))
        nexttab=$((col / 4 + 1))
        i=$((4 * nexttab - col))
        tabstr=""
        while [ $i -gt 0 ]; do
            tabstr="$tabstr "
            i=$((i - 1))
        done
        insert_str "$tabstr"
    #else
    #    # TODO multiple-column character don't work
    #    cmd_insert_byte "$tab"
    #fi
    refresh_line $current_row
    update_cursor
}

cmd_insert_enter() {
    # Split current line
    strstart $current_col "$current_linetext"
    start=$str_result
    strend $current_col "$current_linetext"
    end=$str_result
    setrow $current_row "$start"
    
    current_row=$((current_row+1))
    insertline $current_row "$end"
    current_linetext=$end
    current_linelen=${#end}
    current_col=1
    current_lastcol=$current_col
    unset str_result start end
    
    scroll_if_needed || true
    # TODO do something more efficient
    refresh
}

cmd_insert_byte() {
    insert_str "$1"
    # TODO don't refresh the whole line?
    #      it might be possible to use insert mode, but then it might not work with UTF-8
    #printf "\033[4h" (and "l" to disable)
    refresh_line $current_row
    #update_cursor
    refresh_status
}

# bash-only
# read -s -N 1 ch

# hd

getchars() {
    if [ $use_bash_read = 1 ]; then
        read -s -N $1 ch
        printf %s "$ch"
    elif [ $use_head = 1 ]; then
        head -c $1
    else
        dd bs=$1 count=1 status=none
    fi
    #head -c $1
    # | hd -v -e '/1 "%02X "'
}

getmodname() {
    case "$1" in
        2) modname=shift;;
        3) modname=alt;;
        4) modname=alt_shift;;
        5) modname=ctrl;;
        6) modname=ctrl_shift;;
        7) modname=ctrl_alt;;
        8) modname=ctrl_alt_shift;;
        *)
            modname=badmod
            kbd_error "unknown key modifier $1";;
    esac
}

modified_key() {
    mod="$(getchars 1)"
    extra="$(getchars 1)"
    if [ "$extra" = "~" ]; then
        getmodname "$mod"
        echo "${modname}_$1"
    else
        kbd_error "unexpected key seq after mod $1: $extra"
    fi
}

# beware that some keys may be used by the terminal emulator or window manager or
# may not be possible to type depending on the keyboard layout:
#   Alt-F<n> keys (W)
#   Ctrl-Alt-F<n> keys (W)
#   Shift-F<n> keys, where n is high (C)
#   Alt-Enter (T)
#   Alt-<any special character> (K)
#   Shift-<any special character> (K)
#   Shift-<any digit 0-9> (K)  (use the corresponding special character instead)
#   Alt-<any digit 0-9> (T)
#   <any modifier>-PgUp/PgDown (T)
#   Alt-Left/Right/Up/Down (T)
#   Ctrl-Alt-Left/Right/Up/Down (T)
#   Ctrl-Escape (W)
#   Ctrl-Alt-Delete (W)
#   <any combination of modifiers>-Tab (W,T)
#   Alt-Space (W)
#   <any modifier>-Backspace (W,C)
#   <any modifier>-Home/End (C)
#
# WM: conflict with Window Manager or OS
# T: conflict with terminal emulator
# K: impossible to type depending on keyboard layout (e.g. Shift-!)
# C: no console code exists or not really standardized
#
readesc() {
    b="$(getchars 1)"
    case "$b" in
    O)
        c="$(getchars 1)"
        case "$c" in
            A) echo up;;
            B) echo down;;
            C) echo right;;
            D) echo left;;
            F) echo end;;
            H) echo home;;
            P) echo f1;;
            Q) echo f2;;
            R) echo f3;;
            S) echo f4;;
            1)
                d="$(getchars 1)"
                if [ "$d" != ";" ]; then
                    kbd_error "unknown ^[O1 escape $d"
                    return
                fi
                mod="$(getchars 1)"
                getmodname "$mod"
                key="$(getchars 1)"
                case "$key" in
                P) echo ${modname}_f1;;
                Q) echo ${modname}_f2;;
                R) echo ${modname}_f3;;
                S) echo ${modname}_f4;;
                *) kbd_error "unkown ^[O1;<mod> key $key";;
                esac;;
            *) kbd_error "unknown ^[O escape $c";;
        esac
        ;;
    "[")
        c2="$(getchars 1)"
        c="$c2"
        case "$c2" in
            0|1|2|3|4|5|6|7|8|9) c2="$(getchars 1)"; c="$c$c2";;
        esac
        case "$c2" in
            0|1|2|3|4|5|6|7|8|9) c2="$(getchars 1)"; c="$c$c2";;
        esac
        case "$c" in
            A) echo up;;
            B) echo down;;
            C) echo right;;
            D) echo left;;
            E) echo kpmiddle;;
            F) echo end;;
            G) echo kpmiddle;;
            H) echo home;;
            Z) echo shift_tab;;
            1~) echo home;; # on keypad
            2~) echo insert;;
            3~) echo delete;;
            4~) echo end;; # on keypad
            5~) echo pageup;;
            6~) echo pagedown;;
            15~) echo f5;;
            17~) echo f6;;
            18~) echo f7;;
            19~) echo f8;;
            20~) echo f9;;
            21~) echo f10;;
            23~) echo f11;;
            24~) echo f12;;
            25~) echo shift_f1;;
            26~) echo shift_f2;;
            28~) echo shift_f3;;
            29~) echo shift_f4;;
            31~) echo shift_f5;;
            32~) echo shift_f6;;
            23~) echo shift_f7;;
            34~) echo shift_f8;;
            "[")
                d="$(getchars 1)"
                case "$d" in
                A) echo f1;;
                B) echo f2;;
                C) echo f3;;
                D) echo f4;;
                E) echo f5;;
                *) kbd_error "unkown ^[[[ escape $d";;
                esac;;
            "1;")
                mod="$(getchars 1)"
                key="$(getchars 1)"
                if [ "$key" = "$lf" ]; then
                    key="$(getchars 1)"
                fi
                getmodname "$mod"
                case "$key" in
                    A) echo ${modname}_up;;
                    B) echo ${modname}_down;;
                    C) echo ${modname}_right;;
                    D) echo ${modname}_left;;
                    H) echo ${modname}_home;;
                    F) echo ${modname}_end;;
                    P) echo ${modname}_f1;;
                    Q) echo ${modname}_f2;;
                    R) echo ${modname}_f3;;
                    S) echo ${modname}_f4;;
                    *)
                        kbd_error "unkown ^[[1; modified key $key";;
                esac
                ;;
            "2;") modified_key insert;;
            "3;")
                mod="$(getchars 1)"
                key="$(getchars 1)"
                if [ "$key" = "$lf" ]; then
                    key="$(getchars 1)"
                fi
                getmodname "$mod"
                case "$key" in
                    "$del126"|~) echo ctrl_delete;;
                    *) kbd_error "unkown ^[[3; modified key $key";;
                esac
                ;;
            "5;") modified_key pageup;;
            "6;") modified_key pageudown;;
            "15;") modified_key f5;;
            "17;") modified_key f6;;
            "18;") modified_key f7;;
            "19;") modified_key f8;;
            "20;") modified_key f9;;
            "21;") modified_key f10;;
            "23;") modified_key f11;;
            "24;") modified_key f12;;
            *) kbd_error "unknown ^[[ escape $c";;
        esac
        ;;
    0|1|2|3|4|5|6|7|8|9|a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p|q|r|s|t|u|v|w|x|y|z) echo alt_$b;;
    "'") echo alt_singlequote;; #X
    "$char7f") echo alt_backspace;;
    "$esc") echo esc_esc;;
    "$tab") echo alt_tab;; #X
    "$del8") echo ctrl_alt_backspace;; #X
    ".") echo alt_dot;; #X
    ",") echo alt_comma;; #X
    "-") echo alt_minus;; #X
    " ") echo alt_space;; #X
    "<") echo alt_lt;; #X
    ">") echo alt_gt;; #X
    "^")
        # Manual entry of Ctrl-<key>, in case the stty command is not available
        c="$(getchars 1)"
        case "$c" in
            0|1|2|3|4|5|6|7|8|9|a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p|q|r|s|t|u|v|w|x|y|z) echo ctrl_$c;;
        esac
        ;;
    *)
        kbd_error "unknown ^[ escape $b"
        #printf %s "$b" | hd
        ;;
    esac
# These are unreliable (don't work in XTerm)
#    .) echo alt_dot;;
#    ,) echo alt_comma;;
#    -) echo alt_minus;;
}

readmbchar() {
    keycode=$(printf %d "'$1")
    if [ $keycode -ge 192  -a  $keycode -lt 224 ]; then
        utf8len=2
    elif [ $keycode -ge 224  -a  $keycode -lt 240 ]; then
        utf8len=3
    elif [ $keycode -ge 240  -a  $keycode -lt 248 ]; then
        utf8len=4
    else
        # Single-byte character
        # FIXME Bash also gets here because it uses some kind of Unicode strings,
        # where all non-ASCII characters appears to have the value 7 to printf
#        echo "other $1
        mbchar_result=$1
#    printf %s "$1" | hd
        return
    fi
    # UTF-8 multibyte character
    mbchar_result=$1$(getchars $utf8len)
}

getkey() {
    a="$(getchars 1)"
    case "$a" in
    "$esc")
        readesc
        ;;
    "$lf") echo linefeed;;
    "$tab") echo tab;;
    "$char7f") echo backspace;;
    "$ctrl_a") echo ctrl_a;;
    "$ctrl_b") echo ctrl_b;;
    "$ctrl_d") echo ctrl_d;;
    "$ctrl_e") echo ctrl_e;;
    "$ctrl_f") echo ctrl_f;;
    "$ctrl_g") echo ctrl_g;;
    "$ctrl_h") echo ctrl_h;;
    "$ctrl_k") echo ctrl_k;;
    "$ctrl_l") echo ctrl_l;;
    "$ctrl_n") echo ctrl_n;;
    "$ctrl_o") echo ctrl_o;;
    "$ctrl_p") echo ctrl_p;;
    "$ctrl_r") echo ctrl_r;;
    "$ctrl_t") echo ctrl_t;;
    "$ctrl_u") echo ctrl_u;;
    "$ctrl_v") echo ctrl_v;;
    "$ctrl_w") echo ctrl_w;;
    "$ctrl_x") echo ctrl_x;;
    "$ctrl_y") echo ctrl_y;;
    *)
        readmbchar "$a"
        echo "other $mbchar_result"
        ;;
    esac
}

readcmd() {
    getkey
}

while true; do
    cmd="$(readcmd)"
    if [ $bad_input_mode = 1 -a "$cmd" = linefeed ]; then
        # In "bad input mode" keys are echoed and one has to press enter
        # to actually "send" a series of key presses to the editor
        wipe_clean_line
        update_cursor
        trash_row=$((current_row - current_top_row + 1))
        cmd="$(readcmd)"
    fi
    case "$cmd" in
    # Main commands
    ctrl_x) cmd_quit;;
    ctrl_o) cmd_write;;
    ctrl_r) cmd_read;;
    ctrl_w) cmd_search;;
    ctrl_g) cmd_help;;
    ctrl_l) refresh;;
    # Navigation
    left|ctrl_b) cmd_hmove -1;;
    right|ctrl_f) cmd_hmove 1;;
    ctrl_left|alt_b) cmd_nextword;;
    ctrl_right|alt_f) cmd_prevword;;
    home|ctrl_a) cmd_home;;
    end|ctrl_e) cmd_end;;
    up|ctrl_p) cmd_vmove -1;;
    down|ctrl_n) cmd_vmove 1;;
    pageup|ctrl_y) cmd_vscrollmove $((2 - rows));;
    pagedown|ctrl_v) cmd_vscrollmove $((rows - 2));;
    ctrl_home) cmd_top;;
    ctrl_end) cmd_bottom;;
    # Text editing
    delete|ctrl_d) cmd_del_charright;;
    backspace) cmd_del_charleft;;
    ctrl_del|alt_d) cmd_del_wordright;;
    ctrl_bksp) cmd_del_wordleft;;
    tab) cmd_insert_tab;;
    linefeed) cmd_insert_enter;;
    # Visible characters
    other*) cmd_insert_byte "${cmd#other }";;
    # Misc
    #ctrl_*|alt_*|shift_*|f1|f2|f3|f4|f5|f6|f7|f8|f9|f1*) show_error "Unknown command";;
    *) show_error "Unknown command";;
    esac
done

