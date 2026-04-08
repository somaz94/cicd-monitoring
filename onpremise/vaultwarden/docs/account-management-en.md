# Account Management Guide

## Admin Page User Management

**Access**: `https://vault.example.com/admin` → Enter Admin Token

<br/>

### User List

View all registered users in the **Users** tab.

| Actions | Description |
|---------|-------------|
| Deauthorize sessions | Force expire all sessions for the user |
| Delete User | Delete user account |
| Delete SSO Association | Remove SSO link |
| Disable User | Deactivate user (block login) |

<br/>

### Invite User (Admin)

Admin page → Users tab → **Invite User** at bottom → Enter email → **Invite**

> Invitations from the Admin page create accounts **without email verification**.

<br/>

## Organization Member Management

### Invite Members

1. Log in to Web Vault (`https://vault.example.com`)
2. Click **Admin Console** at bottom-left
3. **Members** → **+ Invite member** → Enter email → Set role/collections → Invite

<br/>

### Confirm Invitation (Important!)

> **After inviting a member, you MUST click ⋮ (three dots) → "Confirm" next to the member.**
> Without confirmation, the user remains in invited status and cannot access organization data.

Steps:
1. Send invitation
2. Invited user logs in and accepts invitation
3. **Admin clicks ⋮ → "Confirm" next to the member in the members list**
4. After confirmation, user can access organization data

<br/>

### Roles

| Role | Permissions |
|------|-------------|
| **Owner** | Full org management, member management, all collections, delete org |
| **Admin** | Collection management, invite members, most settings |
| **Manager** | Manage assigned collections + member management |
| **User** | Access assigned collections only (read/write configurable) |

<br/>

### Collection Access Control

Collections group passwords for sharing.

1. Admin Console → **Collections** → Create collection
2. Set per-member access when inviting or afterwards:
   - **Read only**: View passwords only
   - **Read/Write**: Add, edit, delete passwords
   - **Hide passwords**: Auto-fill only, no plaintext view

Example setup:
- **Internal accounts** collection → All team (read only)
- **External accounts** collection → Admins only (read/write)
- **Dev accounts** collection → Dev team only (read/write)

<br/>

## SSO Login Flow

1. User visits `https://vault.example.com`
2. Click **"Enterprise single sign-on (SSO)"** → Enter SSO Identifier (any value, e.g. `gitlab`)
3. Redirected to GitLab login page
4. Complete GitLab authentication
5. **First time**: Set master password (min 12 characters)
6. After: Enter master password to decrypt vault
