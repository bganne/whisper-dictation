SCRIPTS = src/whisper-daemon src/whisper-dictation-toggle install.sh uninstall.sh

.PHONY: check
check:
	shellcheck --shell=bash $(SCRIPTS)
