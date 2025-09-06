#!/bin/bash

# Ensure script runs with UTF-8 encoding to handle Sanskrit and other Unicode text
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# Check for correct number of arguments
# Single-term mode: script expects exactly 2 arguments
# 1. Path to the directory to search
# 2. The search string (can be a regex)
# Multi-term mode: script expects 3 or more arguments
# 1. Path to the directory to search  
# 2. Line count for proximity search
# 3+ Multiple search terms
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <directory_path> <search_string>"
    echo "   or: $0 <directory_path> <line_count> <term1> <term2> [term3] ..."
    echo ""
    echo "Single-term mode: Searches for a single term or pattern"
    echo "Multi-term mode: Searches for 2+ terms within specified line proximity"
    exit 1
fi

# Determine search mode based on argument count
if [ "$#" -eq 2 ]; then
    # Single-term search mode (backward compatible)
    DIRECTORY="$1"
    SEARCH_STRING="$2"
    SEARCH_MODE="single"
elif [ "$#" -ge 3 ]; then
    # Multi-term search mode
    DIRECTORY="$1"
    LINE_COUNT="$2"
    SEARCH_TERMS=("${@:3}")  # All arguments from 3rd onward
    SEARCH_MODE="multi"
    
    # Validate line count is a positive integer
    if ! [[ "$LINE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: Line count must be a positive integer, got: '$LINE_COUNT'"
        exit 1
    fi
    
    if [ "${#SEARCH_TERMS[@]}" -lt 2 ]; then
        echo "Error: Multi-term search requires at least 2 search terms"
        exit 1
    fi
fi
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

# Function to perform multi-term search within specified line proximity
# Returns 0 if 2+ terms found within line count, 1 otherwise
multi_term_search() {
    local text="$1"
    local line_count="$2"
    shift 2
    local patterns=("$@")
    
    # First, quickly check if the text contains at least 2 terms at all
    local found_pattern_count=0
    for pattern in "${patterns[@]}"; do
        if echo "$text" | ggrep -q -i -P "$pattern"; then
            ((found_pattern_count++))
        fi
    done
    
    # If fewer than 2 patterns found in entire text, no need to check proximity
    if [ $found_pattern_count -lt 2 ]; then
        return 1
    fi
    
    # Add line numbers to text for processing
    local numbered_text=$(echo "$text" | ggrep -n ".*")
    
    # Find all matches with line numbers for each pattern, keeping track of which pattern matched which lines
    local pattern_matches_file=$(mktemp)
    for i in "${!patterns[@]}"; do
        local pattern_lines=$(echo "$numbered_text" | ggrep -i -P "${patterns[i]}" | cut -d: -f1)
        if [ -n "$pattern_lines" ]; then
            while IFS= read -r line_num; do
                [ -z "$line_num" ] && continue
                echo "$line_num:${patterns[i]}" >> "$pattern_matches_file"
            done <<< "$pattern_lines"
        fi
    done
    
    # Sort by line number
    sort -n "$pattern_matches_file" > "${pattern_matches_file}.sorted"
    mv "${pattern_matches_file}.sorted" "$pattern_matches_file"
    
    # Check for proximity matches between different terms
    local found_proximity_match=false
    local match_lines=()
    
    # Read all line:pattern pairs and check for different patterns within line_count distance
    local -a line_pattern_pairs
    while IFS=: read -r line_num pattern_name; do
        [ -z "$line_num" ] && continue
        line_pattern_pairs+=("$line_num:$pattern_name")
    done < "$pattern_matches_file"
    
    # Check each pair against all others for proximity of different patterns
    for ((i=0; i<${#line_pattern_pairs[@]}; i++)); do
        IFS=: read -r line1 pattern1 <<< "${line_pattern_pairs[i]}"
        for ((j=i+1; j<${#line_pattern_pairs[@]}; j++)); do
            IFS=: read -r line2 pattern2 <<< "${line_pattern_pairs[j]}"
            
            # Check if patterns are different and within line proximity
            if [ "$pattern1" != "$pattern2" ]; then
                local diff=$((line2 - line1))
                if [ $diff -le $line_count ]; then
                    found_proximity_match=true
                    match_lines+=($line1 $line2)
                    break 2
                fi
            fi
        done
    done
    
    # If proximity match found, generate highlighted output
    if [ "$found_proximity_match" = true ]; then
        # Sort unique match lines and get context
        local unique_lines=($(printf "%s\n" "${match_lines[@]}" | sort -n | uniq))
        local context_start=$((${unique_lines[0]} > 2 ? ${unique_lines[0]} - 2 : 1))
        local last_index=$((${#unique_lines[@]} - 1))
        local context_end=$((${unique_lines[$last_index]} + 2))
        
        # Extract and highlight the context
        echo "$numbered_text" | sed -n "${context_start},${context_end}p" | while IFS=: read -r line_num line_content; do
            local highlighted_line="$line_content"
            for pattern in "${patterns[@]}"; do
                highlighted_line=$(echo "$highlighted_line" | ggrep --color=always -i -P "$pattern" || echo "$highlighted_line")
            done
            echo "$highlighted_line"
        done
        
        # Clean up temp file
        rm -f "$pattern_matches_file"
        return 0
    else
        # Clean up temp file
        rm -f "$pattern_matches_file"
        return 1
    fi
}

# Convert search strings to regex patterns if they contain wildcards
if [ "$SEARCH_MODE" = "single" ]; then
    if [[ "$SEARCH_STRING" == *"*"* ]]; then
        REGEX_PATTERN=$(convert_wildcard_to_regex "$SEARCH_STRING")
        echo "Wildcard pattern detected. Converting '$SEARCH_STRING' to regex: '$REGEX_PATTERN'"
    else
        REGEX_PATTERN="$SEARCH_STRING"
    fi
elif [ "$SEARCH_MODE" = "multi" ]; then
    REGEX_PATTERNS=()
    for term in "${SEARCH_TERMS[@]}"; do
        if [[ "$term" == *"*"* ]]; then
            converted=$(convert_wildcard_to_regex "$term")
            REGEX_PATTERNS+=("$converted")
            echo "Wildcard pattern detected. Converting '$term' to regex: '$converted'"
        else
            REGEX_PATTERNS+=("$term")
        fi
    done
fi

# Verify if the provided directory exists
if [ ! -d "$DIRECTORY" ]; then
    echo "Error: Directory '$DIRECTORY' does not exist."
    exit 1
fi

echo "Starting search in: $DIRECTORY"
if [ "$SEARCH_MODE" = "single" ]; then
    echo "Searching for: '$SEARCH_STRING'"
elif [ "$SEARCH_MODE" = "multi" ]; then
    echo "Multi-term search for 2+ terms within $LINE_COUNT lines:"
    for i in "${!SEARCH_TERMS[@]}"; do
        echo "  Term $((i+1)): '${SEARCH_TERMS[i]}'"
    done
fi
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
        if [ "$SEARCH_MODE" = "single" ]; then
            # Single-term search using ggrep with Perl regex (-P), case-insensitive (-i), and 2 lines of context (-C 2)
            MATCHES=$(echo "$TEXT" | ggrep -i -C 2 --color=always -P "$REGEX_PATTERN")
            if [[ -n "$MATCHES" ]]; then
                echo "$MATCHES"
                echo "File: $file"
                echo "-----------------------------------"
                MATCH_COUNT=$((MATCH_COUNT + 1))
            fi
        elif [ "$SEARCH_MODE" = "multi" ]; then
            # Multi-term search within line proximity
            if multi_term_search "$TEXT" "$LINE_COUNT" "${REGEX_PATTERNS[@]}"; then
                echo "File: $file"
                echo "-----------------------------------"
                MATCH_COUNT=$((MATCH_COUNT + 1))
            fi
        fi
    fi
done

# Final Summary
echo "$MATCH_COUNT"
if [ "$MATCH_COUNT" -eq 0 ]; then
    if [ "$SEARCH_MODE" = "single" ]; then
        echo "No matches found for '$SEARCH_STRING'."
    elif [ "$SEARCH_MODE" = "multi" ]; then
        echo "No files found with 2+ terms within $LINE_COUNT lines."
    fi
else
    if [ "$SEARCH_MODE" = "single" ]; then
        echo "Search complete: Found $MATCH_COUNT matches."
    elif [ "$SEARCH_MODE" = "multi" ]; then
        echo "Search complete: Found $MATCH_COUNT files with 2+ terms within $LINE_COUNT lines."
    fi
fi
