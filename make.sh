#!/bin/zsh

swift build -c release

rm ~/repos/tmall-app/Venders/rswift/rswift

cp ./.build/release/rswift ~/repos/tmall-app/Venders/rswift/rswift
