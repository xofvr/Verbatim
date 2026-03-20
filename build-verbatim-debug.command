#!/bin/zsh
set -euo pipefail

PROJECT="/Users/far/Desktop/Projects/Verbatim/Verbatim.xcodeproj"
SCHEME="Verbatim"

xcodebuild \
  -skipMacroValidation \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
