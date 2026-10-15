"""Write mcp/published-tools.json from the code (see aidc_mcp/publish.py)."""
import sys

from aidc_mcp.publish import main

if __name__ == "__main__":
    sys.exit(main())
