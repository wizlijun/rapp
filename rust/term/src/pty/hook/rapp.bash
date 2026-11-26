# rApp shell integration for bash 3.2 and later. rapp-term starts bash as `bash --init-file <this file> -i`, so bash
# reads this instead of ~/.bashrc; this reads the user's files the way bash would have (the login files when
# RAPP_BASH_LOGIN=1, else ~/.bashrc). At each prompt it reports the directory and the virtual environments
# (OSC 7502 state, only when they changed) and marks the prompt (OSC 133;A); before each command line it reports
# the line (OSC 7502 run), unless a DEBUG trap is already set (then it reports no commands).
# Written by rapp-term; changes here are overwritten.
if [ "${RAPP_BASH_LOGIN-}" = 1 ]; then
  unset RAPP_BASH_LOGIN
  if [ -r /etc/profile ]; then . /etc/profile; fi
  if [ -r ~/.bash_profile ]; then . ~/.bash_profile
  elif [ -r ~/.bash_login ]; then . ~/.bash_login
  elif [ -r ~/.profile ]; then . ~/.profile
  fi
else
  unset RAPP_BASH_LOGIN
  if [ -r ~/.bashrc ]; then . ~/.bashrc; fi
fi

_rapp_b64() { printf %s "$1" | base64 | tr -d '\n'; }

_rapp_state() {
  local now="$PWD"$'\n'"${VIRTUAL_ENV-}"$'\n'"${CONDA_PREFIX-}"$'\n'"${CONDA_DEFAULT_ENV-}"
  if [ "$now" != "${_rapp_last-}" ]; then
    _rapp_last=$now
    local s=state
    if [ -n "$PWD" ]; then s="$s;cwd=$(_rapp_b64 "$PWD")"; fi
    if [ -n "${VIRTUAL_ENV-}" ]; then s="$s;venv=$(_rapp_b64 "$VIRTUAL_ENV")"; fi
    if [ -n "${CONDA_PREFIX-}" ]; then s="$s;conda=$(_rapp_b64 "$CONDA_PREFIX")"; fi
    if [ -n "${CONDA_DEFAULT_ENV-}" ]; then s="$s;conda_name=$(_rapp_b64 "$CONDA_DEFAULT_ENV")"; fi
    printf '\033]7502;%s\007' "$s"
  fi
}

# The newest history entry: its number in _rapp_hnum, its text in _rapp_hline.
_rapp_hist() {
  local h
  h=$(HISTTIMEFORMAT= builtin history 1)
  h=${h#"${h%%[![:space:]]*}"}
  _rapp_hnum=${h%%[!0-9]*}
  h=${h#"$_rapp_hnum"}
  h=${h#[* ]}
  _rapp_hline=${h# }
}

# First in PROMPT_COMMAND: keeps $? for the user's prompt commands, and tells the DEBUG trap a prompt is coming.
_rapp_pre() { return $?; }

# Last in PROMPT_COMMAND.
_rapp_prompt() {
  local ret=$?
  {
    if [ -z "${_rapp_hinit-}" ]; then
      _rapp_hinit=1
      _rapp_hist
    fi
    _rapp_state
    printf '\033]133;A\007'
  } 2>/dev/null
  _rapp_ready=1
  return $ret
}

# The DEBUG trap: runs before every simple command, reports only the first one after a prompt. An entry that did
# not reach the history (ignorespace, ignoredups, history off) is reported by its first simple command.
_rapp_debug() {
  if [ -z "${_rapp_ready-}" ] || [ -n "${COMP_LINE-}" ]; then return 0; fi
  _rapp_ready=
  if [ "$BASH_COMMAND" = _rapp_pre ]; then return 0; fi
  {
    local c= n=${_rapp_hnum-}
    if [[ -o history ]]; then
      _rapp_hist
      if [ -n "$_rapp_hnum" ] && [ "$_rapp_hnum" != "$n" ]; then c=$_rapp_hline; fi
    fi
    if [ -z "$c" ]; then c=$BASH_COMMAND; fi
    printf '\033]7502;run;%s\007' "$(_rapp_b64 "$c")"
  } 2>/dev/null
  return 0
}

# The environment of the terminal this one restores: conda first, then the venv (often made on conda's python).
if [ -n "${RAPP_RESTORE_CONDA-}" ]; then
  if [ -d "$RAPP_RESTORE_CONDA" ] && type conda >/dev/null 2>&1; then
    conda activate "$RAPP_RESTORE_CONDA"
  else
    printf '%s\n' "rApp：上次的环境 $RAPP_RESTORE_CONDA 已不在，没有激活"
  fi
fi
if [ -n "${RAPP_RESTORE_VENV-}" ]; then
  if [ -r "$RAPP_RESTORE_VENV/bin/activate" ]; then
    . "$RAPP_RESTORE_VENV/bin/activate"
  else
    printf '%s\n' "rApp：上次的环境 $RAPP_RESTORE_VENV 已不在，没有激活"
  fi
fi
unset RAPP_RESTORE_CONDA RAPP_RESTORE_VENV

# Beside the user's own prompt commands, never instead of them. bash 5.1 runs every element of an array.
if [ "${#PROMPT_COMMAND[@]}" -gt 1 ] && { [ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }; }; then
  PROMPT_COMMAND=(_rapp_pre "${PROMPT_COMMAND[@]}" _rapp_prompt)
else
  PROMPT_COMMAND="_rapp_pre"$'\n'"${PROMPT_COMMAND-}"$'\n'"_rapp_prompt"
fi
# "$_" as the last word keeps $_ for the user's command.
if [ -z "$(trap -p DEBUG)" ]; then
  trap '_rapp_debug "$_"' DEBUG
fi
