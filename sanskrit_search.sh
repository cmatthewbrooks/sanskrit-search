#!/bin/bash

# Ensure script runs with UTF-8 encoding to handle Sanskrit and other Unicode text
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# Check for correct number of arguments: script expects exactly 2
# 1. Path to the directory to search
# 2. The search string (can be a regex)
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <directory_path> <search_string>"
    exit 1
fi

DIRECTORY="$1"
SEARCH_STRING="$2"
MATCH_COUNT=0
DOC_COUNT=0
DOCX_COUNT=0

# Function to convert wildcard pattern to regex
# Converts * to match any characters within a word (non-whitespace characters)
# while escaping other regex special characters
convert_wildcard_to_regex() {
    local pattern="$1"
    # Escape regex special characters except *
    pattern=$(echo "$pattern" | sed 's/[[\\.^$()+{}|]/\\&/g')
    # Convert * to [^\s]* to match non-whitespace characters (single word)
    pattern=$(echo "$pattern" | sed 's/\*/[^\\s]*/g')
    echo "$pattern"
}

# Convert search string to regex pattern if it contains wildcards
if [[ "$SEARCH_STRING" == *"*"* ]]; then
    REGEX_PATTERN=$(convert_wildcard_to_regex "$SEARCH_STRING")
    echo "Wildcard pattern detected. Converting '$SEARCH_STRING' to regex: '$REGEX_PATTERN'"
else
    REGEX_PATTERN="$SEARCH_STRING"
fi

# Verify if the provided directory exists
if [ ! -d "$DIRECTORY" ]; then
    echo "Error: Directory '$DIRECTORY' does not exist."
    exit 1
fi

echo "Starting search in: $DIRECTORY"
echo "Searching for: '$SEARCH_STRING'"
echo "-----------------------------------"

# Find all .doc and .docx files and count them separately
DOC_FILES=$(find "$DIRECTORY" -type f -name "*.doc")
DOCX_FILES=$(find "$DIRECTORY" -type f -name "*.docx")
DOC_COUNT=$(echo "$DOC_FILES" | wc -l | tr -d ' ')   # Count .doc files
DOCX_COUNT=$(echo "$DOCX_FILES" | wc -l | tr -d ' ') # Count .docx files

TOTAL_FILES=$((DOC_COUNT + DOCX_COUNT))
if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "No .doc or .docx files found in the directory."
    exit 0
fi

echo "Found $DOC_COUNT .doc files and $DOCX_COUNT .docx files."
echo "Processing files..."
echo "-----------------------------------"

# Process each .doc and .docx file found
find "$DIRECTORY" \( -name "*.doc" -o -name "*.docx" \) | while IFS= read -r file; do
    echo "Processing: $file"
    
    # Extract text from .doc using antiword and convert encoding to UTF-8
    if [[ "$file" == *.doc ]]; then
        TEXT=$(antiword "$file" 2>/dev/null | iconv -f ISO-8859-1 -t UTF-8)
    # Extract text from .docx using docx2txt
    elif [[ "$file" == *.docx ]]; then
        TEXT=$(./docx2txt "$file" "-" 2>/dev/null)
    fi

    if [[ -n "$TEXT" ]]; then
        # Search for the string using ggrep with Perl regex (-P), case-insensitive (-i), and 2 lines of context (-C 2)
        MATCHES=$(echo "$TEXT" | ggrep -i -C 2 --color=always -P "$REGEX_PATTERN")
        if [[ -n "$MATCHES" ]]; then
            echo "$MATCHES"
            echo "File: $file"
            echo "-----------------------------------"
            MATCH_COUNT=$((MATCH_COUNT + 1))
        fi
    fi
done

# Final Summary
echo "$MATCH_COUNT"
if [ "$MATCH_COUNT" -eq 0 ]; then
    echo "No matches found for '$SEARCH_STRING'."
else
    echo "Search complete: Found $MATCH_COUNT matches."
fi
