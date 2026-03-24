# Local backend (static file server)

This is a tiny local `localhost` backend for the files in this folder.

## Run (PowerShell)

```powershell
.\server.ps1
```

Optional:

```powershell
.\server.ps1 -Port 3010
```

Open one of:

- `http://localhost:3000/` (serves `yellow-circle.html` by default)
- `http://localhost:3000/yellow-circle.html`
- `http://localhost:3000/health` (returns `{ ok: true, ... }`)

## Notes

- This backend serves static files and exposes a small persistence API.
- It does not persist or store your app data (the HTML uses in-browser `sessionStorage`).

## Optional: Node version

There is also a dependency-free `server.js` if you have Node.js installed.

### Persistence details

- Data is stored in `yc_data.json` in this same folder.
- API:
  - `GET /api/state` loads the saved state (or returns `{ seeded:false }` if none exists yet)
  - `POST /api/saveState` saves the full app state

