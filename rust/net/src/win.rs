//! Every Windows system call rapp makes outside the Windows host and supervisor crates (spec §8).
//! The only file in the shared crates with Windows `unsafe`; everything else calls the safe
//! functions here (or `private`, `proc`, which use them).

use std::ffi::OsStr;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;

use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, LocalFree, ERROR_ALREADY_EXISTS, ERROR_SUCCESS, HANDLE, HLOCAL};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSidToSidW, GetNamedSecurityInfoW, SetEntriesInAclW, SetNamedSecurityInfoW, EXPLICIT_ACCESS_W,
    NO_MULTIPLE_TRUSTEE, SET_ACCESS, SE_FILE_OBJECT, TRUSTEE_IS_SID, TRUSTEE_IS_UNKNOWN, TRUSTEE_W,
};
use windows_sys::Win32::Security::{
    GetAce, GetSecurityDescriptorControl, GetTokenInformation, TokenUser, ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, DACL_SECURITY_INFORMATION,
    NO_INHERITANCE, PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID, SE_DACL_PROTECTED, SUB_CONTAINERS_AND_OBJECTS_INHERIT,
    TOKEN_QUERY, TOKEN_USER,
};
use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
use windows_sys::Win32::System::Console::{GetConsoleWindow, SetConsoleOutputCP};
use windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId;
use windows_sys::Win32::System::Threading::{CreateMutexW, GetCurrentProcess, GetCurrentProcessId, OpenProcessToken};

/// `FILE_ALL_ACCESS` (what `icacls` shows as `F`), as the plain `u32` the access entry takes.
const FILE_ALL_ACCESS: u32 = 0x001F_01FF;
/// `ACCESS_ALLOWED_ACE_TYPE` (`Win32_System_SystemServices` has it as `u32`; the header field is `u8`).
const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;
/// The UTF-8 code page.
const CP_UTF8: u32 = 65001;

/// `s` as a NUL-terminated UTF-16 string. An inner NUL would silently cut the name, so it is an error.
fn wide(s: &OsStr) -> io::Result<Vec<u16>> {
    let mut w: Vec<u16> = s.encode_wide().collect();
    if w.contains(&0) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "name contains a NUL character"));
    }
    w.push(0);
    Ok(w)
}

fn win32(code: u32) -> io::Result<()> {
    if code == ERROR_SUCCESS {
        Ok(())
    } else {
        Err(io::Error::from_raw_os_error(code as i32))
    }
}

/// The login session this process is in (0 if the system will not say, which it always does).
pub fn session_id() -> u32 {
    let mut id = 0u32;
    // SAFETY: `id` is a valid out pointer for the duration of the call.
    let ok = unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut id) };
    if ok == 0 {
        0
    } else {
        id
    }
}

/// A named mutex this process created. Closed on drop; the system closes it if the process dies.
#[derive(Debug)]
pub struct NamedMutex(HANDLE);

// SAFETY: the handle is only ever closed (in `drop`); a kernel handle may be closed from any thread.
unsafe impl Send for NamedMutex {}
// SAFETY: no method uses the handle through `&self`.
unsafe impl Sync for NamedMutex {}

impl NamedMutex {
    /// `Ok(None)` when a mutex of that name already exists (another process, or this one, holds it).
    pub fn acquire(name: &str) -> io::Result<Option<NamedMutex>> {
        let w = wide(OsStr::new(name))?;
        // SAFETY: `w` is NUL-terminated and outlives the call; null attributes mean the default
        // security descriptor; the last error is read right after the call, before anything else.
        unsafe {
            let h = CreateMutexW(std::ptr::null(), 0, w.as_ptr());
            if h.is_null() {
                return Err(io::Error::last_os_error());
            }
            if GetLastError() == ERROR_ALREADY_EXISTS {
                CloseHandle(h);
                return Ok(None);
            }
            Ok(Some(NamedMutex(h)))
        }
    }
}

impl Drop for NamedMutex {
    fn drop(&mut self) {
        // SAFETY: `self.0` is a handle this value owns and closes exactly once.
        unsafe {
            CloseHandle(self.0);
        }
    }
}

/// Switches the console's output code page to UTF-8; nothing when there is no console.
pub fn console_utf8() {
    if has_console() {
        // SAFETY: plain call without pointers.
        unsafe {
            SetConsoleOutputCP(CP_UTF8);
        }
    }
}

/// Whether this process has a console window.
pub fn has_console() -> bool {
    // SAFETY: plain call without pointers.
    !unsafe { GetConsoleWindow() }.is_null()
}

/// `(total, available to this user)` bytes of the volume that holds `path` (any directory on it).
pub fn disk_space(path: &Path) -> io::Result<(u64, u64)> {
    let w = wide(path.as_os_str())?;
    let (mut avail, mut total, mut free) = (0u64, 0u64, 0u64);
    // SAFETY: `w` is NUL-terminated and outlives the call; the three out pointers are valid.
    let ok = unsafe { GetDiskFreeSpaceExW(w.as_ptr(), &mut avail, &mut total, &mut free) };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((total, avail))
}

/// A SID as its string form (`S-1-5-…`).
///
/// SAFETY: `sid` must point to a valid SID.
unsafe fn sid_string(sid: PSID) -> io::Result<String> {
    let mut s: *mut u16 = std::ptr::null_mut();
    if ConvertSidToStringSidW(sid, &mut s) == 0 {
        return Err(io::Error::last_os_error());
    }
    let mut n = 0usize;
    while *s.add(n) != 0 {
        n += 1;
    }
    let out = String::from_utf16_lossy(std::slice::from_raw_parts(s, n));
    LocalFree(s as HLOCAL);
    Ok(out)
}

/// The `TOKEN_USER` of this process, in a buffer aligned for it. The SID it points to lives in the
/// same buffer, so the buffer must outlive every use of that SID.
fn token_user() -> io::Result<Vec<u64>> {
    // SAFETY: the token handle is closed on every path; the buffer is sized by the first call and
    // 8-byte aligned, which `TOKEN_USER` needs.
    unsafe {
        let mut tok: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut tok) == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut len = 0u32;
        GetTokenInformation(tok, TokenUser, std::ptr::null_mut(), 0, &mut len);
        if len == 0 {
            let e = io::Error::last_os_error();
            CloseHandle(tok);
            return Err(e);
        }
        let mut buf = vec![0u64; (len as usize).div_ceil(8)];
        let ok = GetTokenInformation(tok, TokenUser, buf.as_mut_ptr().cast(), (buf.len() * 8) as u32, &mut len);
        let e = io::Error::last_os_error();
        CloseHandle(tok);
        if ok == 0 {
            return Err(e);
        }
        Ok(buf)
    }
}

/// The SID of the user this process runs as, e.g. `S-1-5-21-…-1001` (`S-1-5-18` for SYSTEM).
pub fn current_user_sid() -> io::Result<String> {
    let buf = token_user()?;
    // SAFETY: `buf` holds a `TOKEN_USER` filled by the system; its SID points into `buf`.
    unsafe {
        let tu = &*(buf.as_ptr() as *const TOKEN_USER);
        sid_string(tu.User.Sid)
    }
}

/// A SID made from its string form; freed with `LocalFree` on drop.
struct LocalSid(PSID);

impl LocalSid {
    fn parse(s: &str) -> io::Result<LocalSid> {
        let w = wide(OsStr::new(s))?;
        let mut sid: PSID = std::ptr::null_mut();
        // SAFETY: `w` is NUL-terminated; `sid` is a valid out pointer.
        if unsafe { ConvertStringSidToSidW(w.as_ptr(), &mut sid) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(LocalSid(sid))
    }
}

impl Drop for LocalSid {
    fn drop(&mut self) {
        // SAFETY: allocated by `ConvertStringSidToSidW`, freed once.
        unsafe {
            LocalFree(self.0 as HLOCAL);
        }
    }
}

/// Replaces the DACL of `path` by one with full control for this user and the SIDs in `others`,
/// marked protected (nothing inherited from the parent). `inherit`: the entries are inherited by
/// files and folders created inside (for a directory).
pub fn set_private(path: &Path, others: &[&str], inherit: bool) -> io::Result<()> {
    let name = wide(path.as_os_str())?;
    let user = token_user()?;
    let others: Vec<LocalSid> = others.iter().map(|s| LocalSid::parse(s)).collect::<io::Result<_>>()?;
    // SAFETY: `user` and `others` outlive every SID pointer taken from them; the new ACL is freed
    // with `LocalFree` on every path after it was made.
    unsafe {
        let user_sid = (*(user.as_ptr() as *const TOKEN_USER)).User.Sid;
        let entry = |sid: PSID| EXPLICIT_ACCESS_W {
            grfAccessPermissions: FILE_ALL_ACCESS,
            grfAccessMode: SET_ACCESS,
            grfInheritance: if inherit { SUB_CONTAINERS_AND_OBJECTS_INHERIT } else { NO_INHERITANCE },
            Trustee: TRUSTEE_W {
                pMultipleTrustee: std::ptr::null_mut(),
                MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
                TrusteeForm: TRUSTEE_IS_SID,
                TrusteeType: TRUSTEE_IS_UNKNOWN,
                ptstrName: sid as *mut u16,
            },
        };
        let entries: Vec<EXPLICIT_ACCESS_W> = std::iter::once(user_sid).chain(others.iter().map(|s| s.0)).map(entry).collect();
        let mut acl: *mut ACL = std::ptr::null_mut();
        win32(SetEntriesInAclW(entries.len() as u32, entries.as_ptr(), std::ptr::null(), &mut acl))?;
        let r = SetNamedSecurityInfoW(
            name.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            acl,
            std::ptr::null(),
        );
        LocalFree(acl as HLOCAL);
        win32(r)
    }
}

/// The DACL of `path`: whether it is protected, and the SIDs of its access-allowed entries in the
/// order they appear (duplicates kept). A NULL DACL (everyone may do anything) reads as `S-1-1-0`.
pub fn read_acl(path: &Path) -> io::Result<(bool, Vec<String>)> {
    let name = wide(path.as_os_str())?;
    // SAFETY: the security descriptor is freed with `LocalFree` on every path after it was
    // returned; the DACL and its entries point into it.
    unsafe {
        let mut dacl: *mut ACL = std::ptr::null_mut();
        let mut sd: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
        win32(GetNamedSecurityInfoW(
            name.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut dacl,
            std::ptr::null_mut(),
            &mut sd,
        ))?;
        let result = (|| {
            let (mut control, mut rev) = (0u16, 0u32);
            if GetSecurityDescriptorControl(sd, &mut control, &mut rev) == 0 {
                return Err(io::Error::last_os_error());
            }
            let protected = control & SE_DACL_PROTECTED != 0;
            if dacl.is_null() {
                return Ok((protected, vec!["S-1-1-0".to_string()]));
            }
            let mut sids = Vec::new();
            for i in 0..u32::from((*dacl).AceCount) {
                let mut ace: *mut core::ffi::c_void = std::ptr::null_mut();
                if GetAce(dacl, i, &mut ace) == 0 {
                    return Err(io::Error::last_os_error());
                }
                if (*(ace as *const ACE_HEADER)).AceType == ACCESS_ALLOWED_ACE_TYPE {
                    let sid = std::ptr::addr_of_mut!((*(ace as *mut ACCESS_ALLOWED_ACE)).SidStart) as PSID;
                    sids.push(sid_string(sid)?);
                }
            }
            Ok((protected, sids))
        })();
        LocalFree(sd as HLOCAL);
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_disk_of_the_temp_dir_has_room() {
        let d = tempfile::tempdir().unwrap();
        let (total, avail) = disk_space(d.path()).unwrap();
        assert!(total > 0 && avail <= total, "{total} {avail}");
        assert!(disk_space(&d.path().join("missing")).is_err());
    }

    #[test]
    fn named_mutex_is_exclusive_and_released() {
        let name = format!(r"Local\rapp-test-{}", std::process::id());
        let a = NamedMutex::acquire(&name).unwrap();
        assert!(a.is_some());
        assert!(NamedMutex::acquire(&name).unwrap().is_none());
        drop(a);
        assert!(NamedMutex::acquire(&name).unwrap().is_some());
    }

    #[test]
    fn the_session_and_the_user_are_known() {
        // Any session id is fine (0 for a service); the call must not fail into garbage.
        let _ = session_id();
        let sid = current_user_sid().unwrap();
        assert!(sid.starts_with("S-1-5-"), "{sid}");
    }

    #[test]
    fn a_name_with_a_nul_is_refused() {
        assert!(wide(OsStr::new("a\0b")).is_err());
        assert_eq!(wide(OsStr::new("张")).unwrap(), vec![0x5f20, 0]);
    }
}
