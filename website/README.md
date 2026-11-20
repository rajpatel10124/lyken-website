# Lyken Solutions and Services — deployable website

**Eight pages, approved Premium Icon logo, white/orange visual theme, Node.js contact backend.** No paid npm dependencies or build process.

## Start locally (working website + API)

Install Node.js 20 or newer. Open this folder in a terminal:

```bash
npm start
```

Visit **http://localhost:3000**. Do **not** open `contact.html` using VS Code Live Server: Live Server is static and cannot serve `/api/contact`.

Before email credentials are configured, the website and API run, but the contact form deliberately displays a clear **email service not configured** message instead of pretending a message was sent.

## Configure real email sending

This backend uses the **Brevo transactional email HTTP API**. You need a Brevo account with transactional email enabled, a verified sender identity, and an API key. Provider availability, verification and free-plan terms depend on your account. A domain-based sender is preferable for production deliverability.

1. In Brevo, verify the email address/domain you will send **from**. This is separate from the destination inbox `rajptl244@gmail.com`.
2. Create a Brevo API v3 key. Keep it secret; never paste it into the website or commit it to Git.
3. Set `BREVO_API_KEY` and `BREVO_SENDER_EMAIL` in the **server process environment**. The sender must match your verified sender. Example for macOS/Linux:

```bash
export BREVO_API_KEY='your-secret-api-key'
export BREVO_SENDER_EMAIL='verified-sender@yourdomain.com'
npm start
```

4. Open `http://localhost:3000/contact.html` and submit a real inquiry. Check the API response, Brevo transactional email logs and the destination inbox (including spam). Provider acceptance is **not** a guarantee of final inbox delivery.
5. To test the backend health endpoint, visit `http://localhost:3000/api/health` (`emailConfigured` must be `true`).

## Deploy to Render (single service)

1. Upload this folder to a **private or public GitHub repository**, excluding `.env` and credentials.
2. Create a **Render Web Service** connected to the repository, using Node runtime, start command `npm start` and no build command. `render.yaml` is included for Blueprint deployments; verify the hosting plan and any current limits.
3. In Render environment settings, add `BREVO_API_KEY` and `BREVO_SENDER_EMAIL` as secret environment variables. Do **not** include quotation marks around the values.
4. Deploy and open the provided HTTPS URL. Check `/api/health`, then submit an inquiry on `/contact.html`.
5. Verify the message in Brevo logs and in `rajptl244@gmail.com`. Configure your custom domain and DNS/HTTPS through Render if desired.

The backend serves the frontend and API from **one origin**, so no cross-origin configuration is needed. Hosting this folder on static-only services such as GitHub Pages, VS Code Live Server or a static Netlify site **will not run the Node backend**.

## Tests

```bash
npm test
```

Tests cover all pages, input validation, unconfigured-email response, mocked provider success/failure, and email payload construction. They do **not** prove live email delivery; only an end-to-end test with real credentials can do that.

## Security and operations

- No secrets in browser JavaScript or Git. API key stays server-side.
- Form validation, request size limit, same-origin check, basic in-memory rate limit and spam honeypot are included.
- In-memory rate limits reset on server restart and are not shared across multiple instances; use an edge/WAF rate limiter and CAPTCHA if traffic increases.
- The honeypot silently accepts likely spam without sending an email.
- Never claim the message reached the inbox based only on HTTP 200: the email provider may accept a message that later bounces or is filtered.
- Review the privacy page for your real data handling and retention policy before publishing.

Contact: Raj Patel · rajptl244@gmail.com
