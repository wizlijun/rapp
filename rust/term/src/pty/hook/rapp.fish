# rApp shell integration for fish, sourced by `fish -C` after the user's config. At each prompt it reports the
# directory and the virtual environments (OSC 7502 state, only when they changed) and marks the prompt
# (OSC 133;A); before each command it reports the command line (OSC 7502 run).
# Written by rapp-term; changes here are overwritten.
function _rapp_b64
    printf %s "$argv[1]" | base64 | tr -d '\n'
end

function _rapp_prompt --on-event fish_prompt
    begin
        set -l now "$PWD"\n"$VIRTUAL_ENV"\n"$CONDA_PREFIX"\n"$CONDA_DEFAULT_ENV"
        if test "$now" != "$_rapp_last"
            set -g _rapp_last "$now"
            set -l s state
            if test -n "$PWD"
                set s "$s;cwd="(_rapp_b64 "$PWD")
            end
            if test -n "$VIRTUAL_ENV"
                set s "$s;venv="(_rapp_b64 "$VIRTUAL_ENV")
            end
            if test -n "$CONDA_PREFIX"
                set s "$s;conda="(_rapp_b64 "$CONDA_PREFIX")
            end
            if test -n "$CONDA_DEFAULT_ENV"
                set s "$s;conda_name="(_rapp_b64 "$CONDA_DEFAULT_ENV")
            end
            printf '\e]7502;%s\a' "$s"
        end
        printf '\e]133;A\a'
    end 2>/dev/null
end

function _rapp_preexec --on-event fish_preexec
    begin
        printf '\e]7502;run;%s\a' (_rapp_b64 "$argv[1]")
    end 2>/dev/null
end

# The environment of the terminal this one restores: conda first, then the venv (often made on conda's python).
if test -n "$RAPP_RESTORE_CONDA"
    if test -d "$RAPP_RESTORE_CONDA"; and type -q conda
        conda activate "$RAPP_RESTORE_CONDA"
    else
        echo "rApp：上次的环境 $RAPP_RESTORE_CONDA 已不在，没有激活"
    end
end
if test -n "$RAPP_RESTORE_VENV"
    if test -r "$RAPP_RESTORE_VENV/bin/activate.fish"
        source "$RAPP_RESTORE_VENV/bin/activate.fish"
    else
        echo "rApp：上次的环境 $RAPP_RESTORE_VENV 已不在，没有激活"
    end
end
set -q RAPP_RESTORE_CONDA; and set -e RAPP_RESTORE_CONDA
set -q RAPP_RESTORE_VENV; and set -e RAPP_RESTORE_VENV
