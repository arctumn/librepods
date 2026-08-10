//! AirPods Pro 3 hearing assistance: enable it over AAP (control commands 0x2C /
//! 0x33), then write the amplification settings to the ATT/GATT (PSM 0x001F, handle
//! 0x2A) via a read-modify-write. The layout mirrors the Android client
//! (HearingAidEnums): 8-band EQ per ear + per-ear amplification/tone/conversation-
//! boost as little-endian f32. We leave the audiogram EQ bands untouched for now and
//! drive only the overall amplification / balance / conversation boost.

use crate::aap;
use crate::driver::Driver;
use std::{thread, time::Duration};

// AAP hearing-assist enable/disable (0x09 control commands 0x2C / 0x33).
const HA_ON_2C: [u8; 11] = [0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x2C, 0x01, 0x01, 0x00, 0x00];
const HA_ON_33: [u8; 11] = [0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x33, 0x01, 0x00, 0x00, 0x00];
const HA_OFF_2C: [u8; 11] = [0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x2C, 0x01, 0x02, 0x00, 0x00];
const HA_OFF_33: [u8; 11] = [0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x33, 0x02, 0x00, 0x00, 0x00];

const H_SETTINGS: u16 = 0x002A; // hearing-aid settings characteristic
const H_CCCD: u16 = 0x002B; // its client-config descriptor

// f32 offsets into the settings value (bytes after the ATT opcode).
const OFF_MODE: usize = 2;
const OFF_LEFT_AMP: usize = 36;
const OFF_LEFT_TONE: usize = 40;
const OFF_LEFT_CONV: usize = 44;
const OFF_RIGHT_AMP: usize = 84;
const OFF_RIGHT_TONE: usize = 88;
const OFF_RIGHT_CONV: usize = 92;

fn put_f32(buf: &mut [u8], off: usize, v: f32) {
    if off + 4 <= buf.len() {
        buf[off..off + 4].copy_from_slice(&v.to_le_bytes());
    }
}

fn att_read_req(handle: u16) -> [u8; 3] {
    [0x0A, (handle & 0xff) as u8, (handle >> 8) as u8]
}

fn att_write_pdu(handle: u16, value: &[u8]) -> Vec<u8> {
    let mut p = vec![0x12u8, (handle & 0xff) as u8, (handle >> 8) as u8];
    p.extend_from_slice(value);
    p
}

/// Apply hearing-assist settings. Requires the AAP + ATT channels to be up (the
/// driver opens ATT on connect). Returns a short summary for the daemon log.
pub fn apply(
    drv: &Driver,
    on: bool,
    amplification: f32,
    balance: f32,
    conv_boost: bool,
) -> Result<String, String> {
    if !on {
        let _ = drv.send(&HA_OFF_33);
        thread::sleep(Duration::from_millis(300));
        let _ = drv.send(&HA_OFF_2C);
        return Ok("hearing aid OFF".into());
    }

    // 1) Wake the buds' hearing-aid ATT server (it is dormant until enabled), and
    // switch to Transparency (mode 3) so ambient sound passes through to be
    // amplified — in ANC/Off there is nothing to amplify.
    let _ = drv.send(&HA_ON_2C);
    thread::sleep(Duration::from_millis(300));
    let _ = drv.send(&aap::anc_command(3));
    thread::sleep(Duration::from_millis(200));
    let _ = drv.send(&HA_ON_33);
    thread::sleep(Duration::from_millis(900));

    // 2) Enable notifications on the settings CCCD.
    let mut b = [0u8; 512];
    let _ = drv.att_send(&att_write_pdu(H_CCCD, &[0x01, 0x00]));
    let _ = drv.att_recv(2000, &mut b);

    // 3) Read the current settings value (read-modify-write).
    let _ = drv.att_send(&att_read_req(H_SETTINGS));
    let n = drv
        .att_recv(2000, &mut b)
        .map_err(|e| format!("ATT read err: {e}"))?;
    if n < 8 || b[0] != 0x0B {
        return Err(format!("bad ATT read resp [{n}]"));
    }
    let mut val = b[1..n].to_vec(); // the characteristic value (~104 bytes)

    // 4) Patch amplification / balance / conversation boost. Audiogram EQ untouched.
    let amp = amplification.clamp(0.0, 1.0);
    let bal = balance.clamp(-1.0, 1.0);
    let left_amp = (amp + if bal < 0.0 { -bal } else { 0.0 }).clamp(0.0, 1.0);
    let right_amp = (amp + if bal > 0.0 { bal } else { 0.0 }).clamp(0.0, 1.0);
    let cb = if conv_boost { 1.0f32 } else { 0.0f32 };
    if val.len() > OFF_MODE {
        val[OFF_MODE] = 0x64;
    }
    // Flat audiogram: a broadband gain across all 8 EQ bands per ear. A zero
    // audiogram leaves the amplification nothing to scale (you'd hear nothing), so
    // we synthesize a flat boost from the slider. BAND_GAIN is a first guess at the
    // units (dB-ish) — tune against hardware.
    const BAND_GAIN: f32 = 30.0;
    for i in 0..8usize {
        put_f32(&mut val, 4 + i * 4, left_amp * BAND_GAIN);
        put_f32(&mut val, 52 + i * 4, right_amp * BAND_GAIN);
    }
    put_f32(&mut val, OFF_LEFT_AMP, left_amp);
    put_f32(&mut val, OFF_LEFT_TONE, 0.0);
    put_f32(&mut val, OFF_LEFT_CONV, cb);
    put_f32(&mut val, OFF_RIGHT_AMP, right_amp);
    put_f32(&mut val, OFF_RIGHT_TONE, 0.0);
    put_f32(&mut val, OFF_RIGHT_CONV, cb);

    // 5) Write it back.
    let _ = drv.att_send(&att_write_pdu(H_SETTINGS, &val));
    let wn = drv.att_recv(2000, &mut b).unwrap_or(0);
    let wr = if wn >= 1 && b[0] == 0x13 { "ok" } else { "no-resp" };

    Ok(format!(
        "hearing aid ON: wrote {} bytes leftAmp={left_amp:.2} rightAmp={right_amp:.2} conv={conv_boost} write={wr}",
        val.len()
    ))
}
