# rApp shell integration for zsh, loaded by rapp's .zshenv. At each prompt it reports the directory and the virtual
# environments (OSC 7502 state, only when they changed) and marks the prompt (OSC 133;A); before each command it
# reports the command line (OSC 7502 run). The hooks go in at the first prompt, after the user's .zshrc.
# Written by rapp-term; changes here are overwritten.
autoload -Uz add-zsh-hook

_rapp_b64() { printf %s "$1" | base64 | tr -d '\n' }

_rapp_prompt() {
  emulate -L zsh
  {
    local now="$PWD"$'\0'"${VIRTUAL_ENV-}"$'\0'"${CONDA_PREFIX-}"$'\0'"${CONDA_DEFAULT_ENV-}"
    if [[ "$now" != "${_rapp_last-}" ]]; then
      typeset -g _rapp_last="$now"
      local s=state
      if [[ -n "$PWD" ]]; then s+=";cwd=$(_rapp_b64 "$PWD")"; fi
      if [[ -n "${VIRTUAL_ENV-}" ]]; then s+=";venv=$(_rapp_b64 "$VIRTUAL_ENV")"; fi
      if [[ -n "${CONDA_PREFIX-}" ]]; then s+=";conda=$(_rapp_b64 "$CONDA_PREFIX")"; fi
      if [[ -n "${CONDA_DEFAULT_ENV-}" ]]; then s+=";conda_name=$(_rapp_b64 "$CONDA_DEFAULT_ENV")"; fi
      printf '\033]7502;%s\007' "$s"
    fi
    printf '\033]133;A\007'
  } 2>/dev/null
}

_rapp_precmd() {
  local ret=$?
  _rapp_prompt
  return $ret
}

_rapp_preexec() {
  emulate -L zsh
  { printf '\033]7502;run;%s\007' "$(_rapp_b64 "$1")" } 2>/dev/null
}

# The environment of the terminal this one restores: conda first, then the venv (often made on conda's python).
_rapp_restore() {
  if [[ -n "${RAPP_RESTORE_CONDA-}" ]]; then
    if [[ -d "$RAPP_RESTORE_CONDA" ]] && (( $+commands[conda] || $+functions[conda] )); then
      conda activate "$RAPP_RESTORE_CONDA"
    else
      print -r -- "rApp：上次的环境 $RAPP_RESTORE_CONDA 已不在，没有激活"
    fi
  fi
  if [[ -n "${RAPP_RESTORE_VENV-}" ]]; then
    if [[ -r "$RAPP_RESTORE_VENV/bin/activate" ]]; then
      source "$RAPP_RESTORE_VENV/bin/activate"
    else
      print -r -- "rApp：上次的环境 $RAPP_RESTORE_VENV 已不在，没有激活"
    fi
  fi
  unset RAPP_RESTORE_CONDA RAPP_RESTORE_VENV
}

# Once, at the first prompt: zsh copies the hook list before running it, so this one also reports the first prompt.
_rapp_init() {
  local ret=$?
  { add-zsh-hook -d precmd _rapp_init } 2>/dev/null
  _rapp_restore
  {
    add-zsh-hook precmd _rapp_precmd
    add-zsh-hook preexec _rapp_preexec
  } 2>/dev/null
  _rapp_prompt
  return $ret
}

add-zsh-hook precmd _rapp_init
