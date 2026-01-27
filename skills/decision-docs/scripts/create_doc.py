#!/usr/bin/env python3
"""
Create a new RFC or ADR document with date-based naming.

Usage:
    python create_doc.py rfc "migration to postgres"
    python create_doc.py adr "use rust for backend"
"""

import sys
import os
from datetime import date
from pathlib import Path


def slugify(text):
    """Convert text to a URL-friendly slug."""
    # Convert to lowercase and replace spaces with hyphens
    slug = text.lower().strip()
    slug = slug.replace(" ", "-")
    # Remove any characters that aren't alphanumeric or hyphens
    slug = "".join(c for c in slug if c.isalnum() or c == "-")
    # Remove multiple consecutive hyphens
    while "--" in slug:
        slug = slug.replace("--", "-")
    return slug.strip("-")


def get_template_path(doc_type):
    """Get the path to the template file."""
    if doc_type == "rfc":
        return "docs/rfcs/template.md"
    elif doc_type == "adr":
        return "docs/adrs/template.md"
    else:
        raise ValueError(f"Unknown document type: {doc_type}")


def get_output_dir(doc_type):
    """Get the output directory for the document type."""
    if doc_type == "rfc":
        return "docs/rfcs"
    elif doc_type == "adr":
        return "docs/adrs"
    else:
        raise ValueError(f"Unknown document type: {doc_type}")


def create_document(doc_type, title, project_root=None):
    """
    Create a new RFC or ADR document.

    Args:
        doc_type: Either 'rfc' or 'adr'
        title: Human-readable title for the document
        project_root: Root directory of the project (defaults to current directory)

    Returns:
        Path to the created document
    """
    if project_root is None:
        project_root = Path.cwd()
    else:
        project_root = Path(project_root)

    # Generate filename
    today = date.today().isoformat()
    slug = slugify(title)
    filename = f"{today}-{slug}.md"

    # Get paths
    template_path = project_root / get_template_path(doc_type)
    output_dir = project_root / get_output_dir(doc_type)
    output_path = output_dir / filename

    # Check if template exists
    if not template_path.exists():
        raise FileNotFoundError(f"Template not found: {template_path}")

    # Create output directory if it doesn't exist
    output_dir.mkdir(parents=True, exist_ok=True)

    # Check if file already exists
    if output_path.exists():
        raise FileExistsError(f"Document already exists: {output_path}")

    # Read template and write to output
    template_content = template_path.read_text()
    output_path.write_text(template_content)

    return output_path


def main():
    if len(sys.argv) < 3:
        print("Usage: python create_doc.py <rfc|adr> <title>")
        print()
        print("Examples:")
        print("  python create_doc.py rfc 'migration to postgres'")
        print("  python create_doc.py adr 'use rust for backend'")
        sys.exit(1)

    doc_type = sys.argv[1].lower()
    title = sys.argv[2]

    if doc_type not in ["rfc", "adr"]:
        print(f"Error: Document type must be 'rfc' or 'adr', got '{doc_type}'")
        sys.exit(1)

    try:
        output_path = create_document(doc_type, title)
        print(f"✅ Created {doc_type.upper()}: {output_path}")
        print(f"\nNext steps:")
        print(f"1. Open the file: {output_path}")
        print(f"2. Fill in the sections based on your decision")
        print(f"3. Consider reviewing references/writing-guide.md for tips")
    except FileNotFoundError as e:
        print(f"❌ Error: {e}")
        print("\nMake sure you're running this from the project root directory,")
        print(f"or that docs/{doc_type}s/template.md exists.")
        sys.exit(1)
    except FileExistsError as e:
        print(f"❌ Error: {e}")
        print("\nA document with this name already exists. Try a different title or date.")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
