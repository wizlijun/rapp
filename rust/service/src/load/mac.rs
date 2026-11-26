//! macOS collector: mach host statistics, sysctl and the thermal-pressure notify key. Public APIs only.

use super::{Cpu, Heat, HeatLevel, Mem, Pressure, Sample, Sampler};
use std::ffi::CString;

extern "C" {
    fn notify_register_check(name: *const libc::c_char, out_token: *mut libc::c_int) -> u32;
    fn notify_get_state(token: libc::c_int, state: *mut u64) -> u32;
}

pub(crate) fn pressure_from(level: i32) -> Option<Pressure> {
    match level {
        1 => Some(Pressure::Normal),
        2 => Some(Pressure::Warn),
        4 => Some(Pressure::Critical),
        _ => None,
    }
}

pub(crate) fn heat_from_notify(state: u64) -> HeatLevel {
    match state {
        0 => HeatLevel::Normal,
        1 => HeatLevel::Hot,
        2 => HeatLevel::Serious,
        _ => HeatLevel::Critical,
    }
}

/// Per-CPU ticks are user/system/idle/nice.
pub(crate) fn cpu_pct(prev: &[[u32; 4]], now: &[[u32; 4]]) -> Option<f32> {
    if prev.len() != now.len() || now.is_empty() {
        return None;
    }
    let (mut busy, mut total) = (0u64, 0u64);
    for (p, n) in prev.iter().zip(now) {
        let d = |i: usize| n[i].wrapping_sub(p[i]) as u64;
        busy += d(0) + d(1) + d(3);
        total += d(0) + d(1) + d(2) + d(3);
    }
    if total == 0 {
        return None;
    }
    Some(busy as f32 / total as f32 * 100.0)
}

pub(crate) fn avail_bytes(free: u64, inactive: u64, purgeable: u64, speculative: u64, page: u64) -> u64 {
    (free + inactive + purgeable + speculative) * page
}

fn cpu_ticks() -> Option<Vec<[u32; 4]>> {
    let mut n: libc::natural_t = 0;
    let mut info: libc::processor_info_array_t = std::ptr::null_mut();
    let mut cnt: libc::mach_msg_type_number_t = 0;
    #[allow(deprecated)]
    let host = unsafe { libc::mach_host_self() };
    let kr = unsafe { libc::host_processor_info(host, libc::PROCESSOR_CPU_LOAD_INFO, &mut n, &mut info, &mut cnt) };
    if kr != 0 || info.is_null() {
        return None;
    }
    let per = libc::CPU_STATE_MAX as usize;
    let raw = unsafe { std::slice::from_raw_parts(info, cnt as usize) };
    let out = raw
        .chunks_exact(per)
        .map(|c| [c[0] as u32, c[1] as u32, c[2] as u32, c[3] as u32])
        .collect();
    #[allow(deprecated)]
    unsafe {
        libc::vm_deallocate(
            libc::mach_task_self(),
            info as libc::vm_address_t,
            cnt as libc::vm_size_t * std::mem::size_of::<libc::integer_t>(),
        );
    }
    Some(out)
}

fn sysctl<T: Copy>(name: &str, init: T) -> Option<T> {
    let name = CString::new(name).ok()?;
    let mut v = init;
    let mut len = std::mem::size_of::<T>();
    let rc = unsafe { libc::sysctlbyname(name.as_ptr(), &mut v as *mut T as *mut _, &mut len, std::ptr::null_mut(), 0) };
    (rc == 0).then_some(v)
}

fn mem() -> Option<Mem> {
    let total: u64 = sysctl("hw.memsize", 0u64)?;
    let mut st: libc::vm_statistics64 = unsafe { std::mem::zeroed() };
    let mut cnt = libc::HOST_VM_INFO64_COUNT;
    #[allow(deprecated)]
    let host = unsafe { libc::mach_host_self() };
    let kr = unsafe { libc::host_statistics64(host, libc::HOST_VM_INFO64, &mut st as *mut _ as *mut _, &mut cnt) };
    if kr != 0 {
        return None;
    }
    let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) }.max(0) as u64;
    let avail = avail_bytes(
        st.free_count as u64,
        st.inactive_count as u64,
        st.purgeable_count as u64,
        st.speculative_count as u64,
        page,
    )
    .min(total);
    let swap_used = sysctl("vm.swapusage", unsafe { std::mem::zeroed::<libc::xsw_usage>() }).map(|x| x.xsu_used);
    let pressure = sysctl("kern.memorystatus_vm_pressure_level", 0i32).and_then(pressure_from);
    Some(Mem { total, avail, swap_used, pressure })
}

pub struct MacSampler {
    prev: Option<Vec<[u32; 4]>>,
    /// notify token for the thermal-pressure key, registered once.
    thermal: Option<libc::c_int>,
}

impl MacSampler {
    pub fn new() -> Self {
        let key = CString::new("com.apple.system.thermalpressurelevel").unwrap();
        let mut token: libc::c_int = 0;
        let rc = unsafe { notify_register_check(key.as_ptr(), &mut token) };
        MacSampler { prev: None, thermal: (rc == 0).then_some(token) }
    }

    fn heat(&self) -> Option<Heat> {
        let mut state = 0u64;
        if unsafe { notify_get_state(self.thermal?, &mut state) } != 0 {
            return None;
        }
        Some(Heat { level: heat_from_notify(state), celsius: None })
    }
}

impl Sampler for MacSampler {
    fn sample(&mut self) -> Sample {
        let mut s = Sample { at: super::now_secs(), ..Default::default() };
        if let Some(now) = cpu_ticks() {
            if let Some(pct) = self.prev.as_deref().and_then(|p| cpu_pct(p, &now)) {
                let mut l = [0f64; 1];
                let load1 = (unsafe { libc::getloadavg(l.as_mut_ptr(), 1) } == 1).then_some(l[0] as f32);
                s.cpu = Some(Cpu { pct, cores: now.len() as u32, load1 });
            }
            self.prev = Some(now);
        }
        s.mem = mem();
        s.heat = self.heat();
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pressure_levels() {
        assert_eq!(pressure_from(1), Some(Pressure::Normal));
        assert_eq!(pressure_from(2), Some(Pressure::Warn));
        assert_eq!(pressure_from(4), Some(Pressure::Critical));
        assert_eq!(pressure_from(0), None);
        assert_eq!(pressure_from(3), None);
    }

    #[test]
    fn heat_levels() {
        assert_eq!(heat_from_notify(0), HeatLevel::Normal);
        assert_eq!(heat_from_notify(1), HeatLevel::Hot);
        assert_eq!(heat_from_notify(2), HeatLevel::Serious);
        assert_eq!(heat_from_notify(3), HeatLevel::Critical);
        assert_eq!(heat_from_notify(9), HeatLevel::Critical);
    }

    #[test]
    fn cpu_ticks_pct() {
        let a = [[10, 10, 80, 0], [10, 10, 80, 0]];
        let b = [[30, 10, 160, 0], [10, 30, 160, 0]];
        // each cpu: busy 20 of 100 ticks
        let p = cpu_pct(&a, &b).unwrap();
        assert!((p - 20.0).abs() < 0.01, "{p}");
        assert_eq!(cpu_pct(&a, &a), None);
        assert_eq!(cpu_pct(&a, &b[..1]), None);
    }

    #[test]
    fn avail_arithmetic() {
        assert_eq!(avail_bytes(1, 2, 3, 4, 16384), 10 * 16384);
    }
}
