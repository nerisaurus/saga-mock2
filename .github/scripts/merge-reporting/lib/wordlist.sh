#!/bin/bash
# Wordlist for generating friendly tag names
# Format: adjective-animal combinations (~50 each = 2500 possibilities)

# Adjectives - positive, memorable, distinct, with teaching/education easter eggs
# Includes whimsical and less common terms for variety
ADJECTIVES=(
    "agile"
    "bold"
    "brave"
    "bright"
    "brilliant"
    "calm"
    "clever"
    "considerate"
    "cosmic"
    "daring"
    "diligent"
    "eager"
    "eloquent"
    "enigmatic"
    "epic"
    "erudite"
    "fair"
    "fearless"
    "fierce"
    "flying"
    "gentle"
    "golden"
    "happy"
    "harmonic"
    "heroic"
    "humble"
    "inquisitive"
    "keen"
    "kind"
    "learned"
    "lively"
    "lucky"
    "lunar"
    "magic"
    "mighty"
    "nonchalant"
    "noble"
    "peaceful"
    "pensive"
    "proud"
    "prudent"
    "quick"
    "quiet"
    "radiant"
    "rapid"
    "rising"
    "sagacious"
    "scholarly"
    "serene"
    "shiny"
    "silent"
    "silver"
    "smooth"
    "solar"
    "soaring"
    "speedy"
    "steady"
    "stellar"
    "studious"
    "swift"
    "thoughtful"
    "valiant"
    "vivid"
    "whimsical"
    "wise"
    "witty"
)

# Animals - more obscure and fanciful, including fantasy creatures
# Prefer recognizable but less common real animals, plus some fantasy terms
ANIMALS=(
    "albatross"
    "anemone"
    "badger"
    "barracuda"
    "beaver"
    "bison"
    "capybara"
    "cardinal"
    "cheetah"
    "chimaera"
    "cobra"
    "condor"
    "coyote"
    "crane"
    "dolphin"
    "dragon"
    "echidna"
    "fennec"
    "finch"
    "gazelle"
    "gnome"
    "gopher"
    "griffin"
    "heron"
    "hippogriff"
    "jaguar"
    "kestrel"
    "koala"
    "komodo"
    "lemur"
    "leopard"
    "lynx"
    "marmot"
    "meerkat"
    "mephit"
    "moose"
    "narwhal"
    "nautilus"
    "octopus"
    "otter"
    "pangolin"
    "panther"
    "parrot"
    "pelican"
    "phoenix"
    "pika"
    "puma"
    "quokka"
    "raven"
    "salamander"
    "salmon"
    "sparrow"
    "sprite"
    "tarrasque"
    "tiger"
    "tribble"
    "turtle"
    "unicorn"
    "wallaby"
    "wombat"
    "wolf"
)

# Generate a deterministic friendly name from a seed (commit SHA or similar)
# Usage: generate_friendly_name <seed>
generate_friendly_name() {
    local seed="$1"
    
    if [[ -z "$seed" ]]; then
        echo "error: seed required" >&2
        return 1
    fi
    
    # Convert seed to a number using checksum
    # Use first 8 chars of md5 hash to get a stable number
    local hash
    hash=$(echo -n "$seed" | md5sum | cut -c1-8)
    local num=$((16#$hash))
    
    # Select adjective and animal based on the number
    local adj_count=${#ADJECTIVES[@]}
    local animal_count=${#ANIMALS[@]}
    
    local adj_index=$((num % adj_count))
    local animal_index=$(( (num / adj_count) % animal_count ))
    
    local adjective="${ADJECTIVES[$adj_index]}"
    local animal="${ANIMALS[$animal_index]}"
    
    echo "${adjective}-${animal}"
}

# Get a random friendly name (non-deterministic)
# Usage: random_friendly_name
random_friendly_name() {
    local adj_count=${#ADJECTIVES[@]}
    local animal_count=${#ANIMALS[@]}
    
    local adj_index=$((RANDOM % adj_count))
    local animal_index=$((RANDOM % animal_count))
    
    local adjective="${ADJECTIVES[$adj_index]}"
    local animal="${ANIMALS[$animal_index]}"
    
    echo "${adjective}-${animal}"
}

# If sourced, just export the functions and arrays
# If run directly, demonstrate usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Wordlist library for friendly name generation"
    echo ""
    echo "Adjectives: ${#ADJECTIVES[@]}"
    echo "Animals: ${#ANIMALS[@]}"
    echo "Total combinations: $(( ${#ADJECTIVES[@]} * ${#ANIMALS[@]} ))"
    echo ""
    echo "Example (deterministic from 'abc123'):"
    generate_friendly_name "abc123"
    echo ""
    echo "Example (random):"
    random_friendly_name
fi
