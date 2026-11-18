"""Insert a demo row into Supabase, then retrieve recent rows from public.demo.

Install with: python -m pip install supabase
Set SUPABASE_KEY in your environment before running.
Go to the supabase organization page
Hit "connect" (the green button at the top of the screen)
Scroll down to the text box with NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY in it and copy it
Run this in terminal (same directory as you run the file):
$env:SUPABASE_KEY = "sb_publishable_XXX"

"""

import os

from supabase import create_client


def main() -> None:
    url = "https://uvzzitjxbgkgzwoibbnj.supabase.co"
    key = os.environ["SUPABASE_KEY"]

    supabase = create_client(url, key)
    demo = supabase.table("demo")

    # Empty insert using the table's defaults.
    inserted = demo.insert({}).execute()
    print("Inserted row:")
    print(inserted.data)

    # Fetch the most recently created rows.
    recent = (
        demo.select("id, created_at")
        .order("created_at", desc=True)
        .limit(10)
        .execute()
    )
    print("\nMost recent rows:")
    for row in recent.data:
        print(f"id={row['id']}, created_at={row['created_at']}")


if __name__ == "__main__":
    main()
