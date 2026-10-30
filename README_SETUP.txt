LEXIAA & ELSTAR — MULTI-DEVICE AUTH + ADMIN STUDIO
=================================================

FILES
- index.html: user site, Supabase email/password login, menus, gallery pages, member-code page.
- admin.html: separate admin login and bulk uploader.
- supabase_setup.sql: database, RLS, private Storage bucket and server-side member-code check.
- music.mp3 (optional): place your own audio file beside index.html.

IMPORTANT SETUP (REQUIRED)
1. The admin email shown in the previous screenshot is already set in index.html, admin.html, and supabase_setup.sql.
   If you want a different admin email, change it consistently in all three files before running the SQL.
2. Run the full SQL in Supabase Dashboard > SQL Editor.
3. In Supabase Authentication settings, turn OFF Confirm email if you want registration to create a session immediately.
4. Deploy index.html and admin.html to the same static hosting site (HTTPS). Keep the SQL file private/not served publicly if possible.
5. Create an account from index.html using the configured admin email. Log in to admin.html using that same account.
6. For other devices, users can register/login with the same email/password; each device has its own session and may need to log in separately.

HOW TO USE ADMIN
- Open /admin.html on your site.
- Sign in using the account matching ADMIN_EMAIL.
- Choose PENEMUAN or SECRET to upload images only.
- Choose SECRET ONLY MEMBER to upload images and videos.
- Select multiple files at once.
- In the titles box, enter one title per line matching the order of selected files. If a title line is blank/missing, the filename (without extension) is used.
- Uploads are capped at 50 MB each by the supplied SQL/storage configuration.
- You can view and delete uploaded items in the content list.

MEMBER CODE
- Member code is checked through the Supabase RPC function, not client-side JavaScript.
- A successful code check adds the signed-in user to member_access and opens the member gallery.
- The code is currently set to 999666 in the SQL function. Change it in the function if you want another code; rerun the CREATE OR REPLACE FUNCTION section.
- Anyone who knows the code can activate their own signed-in account. This is a shared code gate, not individual approval by admin. Rotate it if it leaks.

SECURITY
- Do NOT put service_role/secret keys in HTML. The publishable key is intended for frontend use.
- Keep the bucket private. Do not change it to public: member media is protected by Storage RLS and signed URLs.
- The SQL policies use the admin email as an allowlist. Replace the placeholder before running SQL.
- Supabase sessions are per-device/browser. Accounts and uploaded media are shared via Supabase, but each device usually logs in separately.
- Email/password signup across devices requires internet and the same Supabase project. Existing users can log in on other devices; signup creates a shared account in Supabase.
