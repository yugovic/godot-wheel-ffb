// WheelBridge - DirectInput bridge for steering wheels and pedals (input + force feedback).
// Part of the "Godot Wheel FFB" addon. MIT License.
//
// Talks to the game over localhost UDP (text / JSON). Because it does not go through the engine's
// joypad layer, the wheel base (e.g. Simagic) and the pedals (e.g. Heusinkveld) can be separate
// devices: every function is bound to "device + axis".
//
//   WheelBridge.exe --list                  list connected devices, their axes and FFB support
//   WheelBridge.exe --monitor [sec]         print raw axis / button values (to check assignments)
//   WheelBridge.exe --ffbtest <index>       gentle FFB self-test (spring -> left/right -> damper -> vibration)
//   WheelBridge.exe --serve [--port N] [--parent PID] [--log FILE] [--cap 0..1]   used by the game (default)
//   WheelBridge.exe --fake                  virtual wheel + pedals for tests without hardware
//
// Safety: forces always ramp up from 0 (1 s), changes are slew-limited (>= 40 ms to full scale),
// everything fades to 0 when the game stops sending updates for 0.3 s, and all effects stop on exit.

#define _CRT_SECURE_NO_WARNINGS
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define DIRECTINPUT_VERSION 0x0800
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <mmsystem.h>
#include <dinput.h>
#include <mstcpip.h>

#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif

#include <algorithm>
#include <chrono>
#include <cstdarg>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#pragma comment(lib, "dinput8.lib")
#pragma comment(lib, "dxguid.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "winmm.lib")

using Clock = std::chrono::steady_clock;
static double now_sec() {
    static const auto t0 = Clock::now();
    return std::chrono::duration<double>(Clock::now() - t0).count();
}

static FILE* g_log = nullptr;
static void logf(const char* fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    fprintf(stdout, "%s\n", buf); fflush(stdout);
    if (g_log) { fprintf(g_log, "%s\n", buf); fflush(g_log); }
}

static std::string wide_to_utf8(const wchar_t* w) {
    if (!w || !*w) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    std::string s(n > 0 ? n - 1 : 0, '\0');
    if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
    return s;
}

static std::string json_escape(const std::string& s) {
    std::string o;
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') { o += '\\'; o += (char)c; }
        else if (c < 0x20) o += ' ';
        else o += (char)c;
    }
    return o;
}

static std::string guid_str(const GUID& g) {
    char b[64];
    snprintf(b, sizeof(b), "%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X", g.Data1, g.Data2, g.Data3,
             g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3], g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7]);
    return b;
}

// ------------------------------------------------------------------ devices
static const int NAXES = 8;   // X Y Z Rx Ry Rz Slider0 Slider1 (DIJOYSTATE2 order)
static const char* AXIS_NAMES[NAXES] = {"X", "Y", "Z", "Rx", "Ry", "Rz", "S0", "S1"};

struct Effects {
    LPDIRECTINPUTEFFECT constant = nullptr, spring = nullptr, damper = nullptr, friction = nullptr, sine = nullptr;
};

struct Dev {
    int index = 0;
    GUID guid{};
    std::string id, name;
    WORD vid = 0, pid = 0;
    LPDIRECTINPUTDEVICE8W dev = nullptr;
    bool fake = false;
    bool ffb = false;            // device supports force feedback
    bool exclusive = false;      // acquired exclusively (required to play effects)
    bool axis_present[NAXES] = {};
    DWORD axis_ofs[NAXES] = {DIJOFS_X, DIJOFS_Y, DIJOFS_Z, DIJOFS_RX, DIJOFS_RY, DIJOFS_RZ, DIJOFS_SLIDER(0), DIJOFS_SLIDER(1)};
    DWORD ffb_axis_ofs = DIJOFS_X;
    bool have_ffb_axis = false;
    int num_buttons = 0;
    bool acquired = false;
    bool dead = false;
    DIJOYSTATE2 st{};
    bool fx_ready = false;
    Effects fx;
    // values currently being played (-1..1 / 0..1)
    double cur_const = 0, cur_spring = 0, cur_damper = 0, cur_friction = 0, cur_vib = 0;
    long sent_const = 0x7fffffff, sent_spring = -1, sent_damper = -1, sent_friction = -1, sent_vib = -1;
    DWORD sent_period = 0;
    double next_write = 0;       // DirectInput writes are capped at 250 Hz (keeps USB traffic low)
};

static LPDIRECTINPUT8W g_di = nullptr;
static HWND g_hwnd = nullptr;
static std::vector<Dev*> g_devs;
static bool g_fake = false;

struct EnumInst { std::vector<DIDEVICEINSTANCEW> list; };

static BOOL CALLBACK enum_dev_cb(const DIDEVICEINSTANCEW* inst, void* ctx) {
    static_cast<EnumInst*>(ctx)->list.push_back(*inst);
    return DIENUM_CONTINUE;
}

static BOOL CALLBACK enum_obj_cb(const DIDEVICEOBJECTINSTANCEW* o, void* ctx) {
    Dev* d = static_cast<Dev*>(ctx);
    int idx = -1;
    if (o->guidType == GUID_XAxis) idx = 0;
    else if (o->guidType == GUID_YAxis) idx = 1;
    else if (o->guidType == GUID_ZAxis) idx = 2;
    else if (o->guidType == GUID_RxAxis) idx = 3;
    else if (o->guidType == GUID_RyAxis) idx = 4;
    else if (o->guidType == GUID_RzAxis) idx = 5;
    else if (o->guidType == GUID_Slider) idx = (o->dwOfs == DIJOFS_SLIDER(1)) ? 7 : 6;
    if (idx < 0) return DIENUM_CONTINUE;
    d->axis_present[idx] = true;
    DIPROPRANGE pr;
    pr.diph.dwSize = sizeof(DIPROPRANGE);
    pr.diph.dwHeaderSize = sizeof(DIPROPHEADER);
    pr.diph.dwHow = DIPH_BYID;
    pr.diph.dwObj = o->dwType;
    pr.lMin = -32768;
    pr.lMax = 32767;
    d->dev->SetProperty(DIPROP_RANGE, &pr.diph);
    DIPROPDWORD dz;
    dz.diph.dwSize = sizeof(DIPROPDWORD);
    dz.diph.dwHeaderSize = sizeof(DIPROPHEADER);
    dz.diph.dwHow = DIPH_BYID;
    dz.diph.dwObj = o->dwType;
    dz.dwData = 0;
    d->dev->SetProperty(DIPROP_DEADZONE, &dz.diph);
    // effects use the axis that has an actuator (normally X = steering)
    if ((o->dwFlags & DIDOI_FFACTUATOR) && (idx == 0 || !d->have_ffb_axis)) { d->ffb_axis_ofs = o->dwOfs; d->have_ffb_axis = true; }
    return DIENUM_CONTINUE;
}

static void release_effects(Dev* d) {
    LPDIRECTINPUTEFFECT* all[] = {&d->fx.constant, &d->fx.spring, &d->fx.damper, &d->fx.friction, &d->fx.sine};
    for (auto p : all) {
        if (*p) { (*p)->Stop(); (*p)->Unload(); (*p)->Release(); *p = nullptr; }
    }
    d->fx_ready = false;
}

static HRESULT make_effect(Dev* d, const GUID& type, void* params, DWORD size, LPDIRECTINPUTEFFECT* out) {
    DWORD axes[1] = {d->ffb_axis_ofs};
    LONG dirs[1] = {0};
    DIEFFECT e;
    ZeroMemory(&e, sizeof(e));
    e.dwSize = sizeof(DIEFFECT);
    e.dwFlags = DIEFF_CARTESIAN | DIEFF_OBJECTOFFSETS;
    e.dwDuration = INFINITE;
    e.dwSamplePeriod = 0;
    e.dwGain = DI_FFNOMINALMAX;
    e.dwTriggerButton = DIEB_NOTRIGGER;
    e.dwTriggerRepeatInterval = 0;
    e.cAxes = 1;
    e.rgdwAxes = axes;
    e.rglDirection = dirs;
    e.lpEnvelope = nullptr;
    e.cbTypeSpecificParams = size;
    e.lpvTypeSpecificParams = params;
    e.dwStartDelay = 0;
    return d->dev->CreateEffect(type, &e, out, nullptr);
}

static void set_params(LPDIRECTINPUTEFFECT fx, void* params, DWORD size) {
    if (!fx) return;
    DIEFFECT e;
    ZeroMemory(&e, sizeof(e));
    e.dwSize = sizeof(DIEFFECT);
    e.cbTypeSpecificParams = size;
    e.lpvTypeSpecificParams = params;
    fx->SetParameters(&e, DIEP_TYPESPECIFICPARAMS);
}

static void create_effects(Dev* d) {
    release_effects(d);
    if (!d->ffb || !d->exclusive || !d->dev) return;
    DICONSTANTFORCE cf = {0};
    DICONDITION cond;
    ZeroMemory(&cond, sizeof(cond));
    cond.dwPositiveSaturation = 10000;
    cond.dwNegativeSaturation = 10000;
    DIPERIODIC per;
    ZeroMemory(&per, sizeof(per));
    per.dwPeriod = 20000;
    HRESULT r1 = make_effect(d, GUID_ConstantForce, &cf, sizeof(cf), &d->fx.constant);
    HRESULT r2 = make_effect(d, GUID_Spring, &cond, sizeof(cond), &d->fx.spring);
    HRESULT r3 = make_effect(d, GUID_Damper, &cond, sizeof(cond), &d->fx.damper);
    HRESULT r4 = make_effect(d, GUID_Friction, &cond, sizeof(cond), &d->fx.friction);
    HRESULT r5 = make_effect(d, GUID_Sine, &per, sizeof(per), &d->fx.sine);
    logf("[ffb] %s: effects constant=%s spring=%s damper=%s friction=%s sine=%s", d->name.c_str(),
         SUCCEEDED(r1) ? "ok" : "NO", SUCCEEDED(r2) ? "ok" : "NO", SUCCEEDED(r3) ? "ok" : "NO",
         SUCCEEDED(r4) ? "ok" : "NO", SUCCEEDED(r5) ? "ok" : "NO");
    LPDIRECTINPUTEFFECT all[] = {d->fx.constant, d->fx.spring, d->fx.damper, d->fx.friction, d->fx.sine};
    for (auto e : all) if (e) e->Start(1, 0);
    d->fx_ready = d->fx.constant != nullptr || d->fx.spring != nullptr || d->fx.damper != nullptr;
    d->sent_const = 0x7fffffff; d->sent_spring = d->sent_damper = d->sent_friction = d->sent_vib = -1;
}

static bool acquire(Dev* d) {
    if (d->fake) { d->acquired = true; return true; }
    HRESULT hr = d->dev->Acquire();
    if (SUCCEEDED(hr)) {
        if (!d->acquired) logf("[dev] %s acquired%s", d->name.c_str(), d->exclusive ? " (exclusive, FFB)" : "");
        d->acquired = true;
        return true;
    }
    d->acquired = false;
    return false;
}

static Dev* open_device(const DIDEVICEINSTANCEW& inst) {
    Dev* d = new Dev();
    d->guid = inst.guidInstance;
    d->id = guid_str(inst.guidInstance);
    d->name = wide_to_utf8(inst.tszProductName);
    d->vid = LOWORD(inst.guidProduct.Data1);
    d->pid = HIWORD(inst.guidProduct.Data1);
    if (FAILED(g_di->CreateDevice(inst.guidInstance, &d->dev, nullptr)) || !d->dev) { delete d; return nullptr; }
    d->dev->SetDataFormat(&c_dfDIJoystick2);
    DIDEVCAPS caps;
    ZeroMemory(&caps, sizeof(caps));
    caps.dwSize = sizeof(caps);
    if (SUCCEEDED(d->dev->GetCapabilities(&caps))) {
        d->ffb = (caps.dwFlags & DIDC_FORCEFEEDBACK) != 0;
        d->num_buttons = (int)caps.dwButtons;
    }
    // FFB devices: exclusive + background (effects play even when the game window is not focused); fall back to shared
    HRESULT hr = E_FAIL;
    if (d->ffb) {
        hr = d->dev->SetCooperativeLevel(g_hwnd, DISCL_EXCLUSIVE | DISCL_BACKGROUND);
        d->exclusive = SUCCEEDED(hr);
    }
    if (FAILED(hr)) d->dev->SetCooperativeLevel(g_hwnd, DISCL_NONEXCLUSIVE | DISCL_BACKGROUND);
    d->dev->EnumObjects(enum_obj_cb, d, DIDFT_AXIS);
    if (d->ffb) {
        // turn the device's own autocenter off (the game provides the centering force)
        DIPROPDWORD ac;
        ac.diph.dwSize = sizeof(DIPROPDWORD);
        ac.diph.dwHeaderSize = sizeof(DIPROPHEADER);
        ac.diph.dwHow = DIPH_DEVICE;
        ac.diph.dwObj = 0;
        ac.dwData = DIPROPAUTOCENTER_OFF;
        d->dev->SetProperty(DIPROP_AUTOCENTER, &ac.diph);
        DIPROPDWORD gain;
        gain.diph.dwSize = sizeof(DIPROPDWORD);
        gain.diph.dwHeaderSize = sizeof(DIPROPHEADER);
        gain.diph.dwHow = DIPH_DEVICE;
        gain.diph.dwObj = 0;
        gain.dwData = 10000;
        d->dev->SetProperty(DIPROP_FFGAIN, &gain.diph);
    }
    if (acquire(d)) {
        if (d->ffb && d->exclusive) {
            d->dev->SendForceFeedbackCommand(DISFFC_RESET);
            d->dev->SendForceFeedbackCommand(DISFFC_SETACTUATORSON);
            create_effects(d);
        }
    }
    return d;
}

static void close_device(Dev* d) {
    if (d->dev) {
        release_effects(d);
        d->dev->SendForceFeedbackCommand(DISFFC_STOPALL);
        d->dev->Unacquire();
        d->dev->Release();
        d->dev = nullptr;
    }
}

static void make_fake_device() {
    Dev* d = new Dev();
    d->fake = true; d->ffb = true; d->exclusive = true; d->fx_ready = true;
    d->name = "Fake Wheel (test)"; d->id = "FAKE-0000-WHEEL"; d->num_buttons = 16;
    d->axis_present[0] = d->axis_present[1] = d->axis_present[2] = true;
    d->index = (int)g_devs.size();
    d->acquired = true;
    g_devs.push_back(d);
    Dev* p = new Dev();
    p->fake = true;
    p->name = "Fake Pedals (test)"; p->id = "FAKE-0000-PEDAL"; p->num_buttons = 0;
    p->axis_present[0] = p->axis_present[1] = p->axis_present[2] = true;
    p->index = (int)g_devs.size();
    p->acquired = true;
    g_devs.push_back(p);
}

static void rescan_devices(bool verbose) {
    if (g_fake || !g_di) return;
    EnumInst en;
    g_di->EnumDevices(DI8DEVCLASS_GAMECTRL, enum_dev_cb, &en, DIEDFL_ATTACHEDONLY);
    // drop devices that disappeared
    for (Dev* d : g_devs) {
        bool found = false;
        for (auto& i : en.list) if (i.guidInstance == d->guid) found = true;
        if (!found && !d->dead) { d->dead = true; logf("[dev] %s unplugged", d->name.c_str()); close_device(d); }
    }
    for (auto& inst : en.list) {
        bool known = false;
        for (Dev* d : g_devs) if (d->guid == inst.guidInstance && !d->dead) known = true;
        if (known) continue;
        // a re-plugged device reuses its old slot (same index)
        Dev* d = open_device(inst);
        if (!d) continue;
        for (size_t k = 0; k < g_devs.size(); ++k) {
            if (g_devs[k]->dead && g_devs[k]->guid == inst.guidInstance) { d->index = g_devs[k]->index; delete g_devs[k]; g_devs[k] = d; d = nullptr; break; }
        }
        if (d) { d->index = (int)g_devs.size(); g_devs.push_back(d); }
        Dev* nd = nullptr;
        for (Dev* x : g_devs) if (x->guid == inst.guidInstance) nd = x;
        if (nd) logf("[dev] #%d %s  VID %04X PID %04X  buttons=%d  FFB=%s%s", nd->index, nd->name.c_str(), nd->vid, nd->pid,
                     nd->num_buttons, nd->ffb ? "yes" : "no", nd->ffb && !nd->exclusive ? " (exclusive FAILED: another app may hold it)" : "");
    }
    (void)verbose;
}

// ------------------------------------------------------------------ reading input
static double g_fake_t0 = 0;

static void fake_state(Dev* d) {
    double t = now_sec() - g_fake_t0;
    ZeroMemory(&d->st, sizeof(d->st));
    for (int i = 0; i < 4; ++i) d->st.rgdwPOV[i] = 0xFFFFFFFF;
    if (d->id == "FAKE-0000-WHEEL") {
        d->st.lX = (LONG)(std::sin(t * 2.0 * 3.14159265 * 0.25) * 12000.0);   // +-37% left/right, 4 s period
        d->st.rgbButtons[0] = ((int)(t) % 6 == 0) ? 0x80 : 0;
    } else {
        // pedals: -32768 released, +32767 pressed (the inverted layout many pedals use)
        double thr = std::max(0.0, std::sin(t * 0.8));
        double brk = std::max(0.0, std::sin(t * 0.8 + 3.14159265));
        d->st.lX = (LONG)(-32768 + thr * 65535.0);
        d->st.lY = (LONG)(-32768 + brk * 65535.0);
    }
}

static void read_device(Dev* d) {
    if (d->dead) return;
    if (d->fake) { fake_state(d); return; }
    if (!d->dev) return;
    HRESULT hr = d->dev->Poll();
    if (hr == DIERR_INPUTLOST || hr == DIERR_NOTACQUIRED) {
        d->acquired = false;
        if (acquire(d) && d->ffb && d->exclusive) create_effects(d);
        hr = d->dev->Poll();
    }
    if (SUCCEEDED(hr)) hr = d->dev->GetDeviceState(sizeof(DIJOYSTATE2), &d->st);
    if (FAILED(hr)) d->acquired = false;
}

// ------------------------------------------------------------------ FFB
struct FfbCmd {
    int dev = -1;
    double con = 0, spr = 0, dmp = 0, fri = 0, vib = 0, vib_ms = 20;
    double gain = 1.0;
    double last = -1e9;      // time of the last update from the game
};
static FfbCmd g_cmd;
static double g_ramp = 0;    // 0..1: start-up ramp
static double g_cap = 1.0;   // global ceiling from --cap

static long to_di(double v01) {   // 0..1 -> 0..10000
    return (long)std::lround(std::clamp(v01, 0.0, 1.0) * 10000.0);
}

static void apply_ffb(Dev* d, double dt, bool active) {
    double target_gain = active ? std::clamp(g_cmd.gain, 0.0, 1.0) * g_cap * g_ramp : 0.0;
    double tc = (d->index == g_cmd.dev && active) ? std::clamp(g_cmd.con, -1.0, 1.0) : 0.0;
    double ts = (d->index == g_cmd.dev && active) ? std::clamp(g_cmd.spr, 0.0, 1.0) : 0.0;
    double td = (d->index == g_cmd.dev && active) ? std::clamp(g_cmd.dmp, 0.0, 1.0) : 0.0;
    double tf = (d->index == g_cmd.dev && active) ? std::clamp(g_cmd.fri, 0.0, 1.0) : 0.0;
    double tv = (d->index == g_cmd.dev && active) ? std::clamp(g_cmd.vib, 0.0, 1.0) : 0.0;
    tc *= target_gain; ts *= target_gain; td *= target_gain; tf *= target_gain; tv *= target_gain;
    // slew limit (40 ms to full scale); releasing force may go twice as fast
    double step = dt * 25.0;
    auto slew = [&](double& cur, double tgt) {
        double lim = (std::fabs(tgt) < std::fabs(cur)) ? step * 2.0 : step;
        cur += std::clamp(tgt - cur, -lim, lim);
    };
    slew(d->cur_const, tc); slew(d->cur_spring, ts); slew(d->cur_damper, td); slew(d->cur_friction, tf); slew(d->cur_vib, tv);
    if (d->fake) return;
    if (!d->fx_ready || !d->acquired) return;
    double tw = now_sec();
    if (tw < d->next_write) return;
    d->next_write = tw + 0.004;
    long c = (long)std::lround(std::clamp(d->cur_const, -1.0, 1.0) * 10000.0);
    if (c != d->sent_const && d->fx.constant) { DICONSTANTFORCE cf = {c}; set_params(d->fx.constant, &cf, sizeof(cf)); d->sent_const = c; }
    long s = to_di(d->cur_spring);
    if (s != d->sent_spring && d->fx.spring) {
        DICONDITION k; ZeroMemory(&k, sizeof(k));
        k.lPositiveCoefficient = s; k.lNegativeCoefficient = s; k.dwPositiveSaturation = 10000; k.dwNegativeSaturation = 10000;
        set_params(d->fx.spring, &k, sizeof(k)); d->sent_spring = s;
    }
    long dm = to_di(d->cur_damper);
    if (dm != d->sent_damper && d->fx.damper) {
        DICONDITION k; ZeroMemory(&k, sizeof(k));
        k.lPositiveCoefficient = dm; k.lNegativeCoefficient = dm; k.dwPositiveSaturation = 10000; k.dwNegativeSaturation = 10000;
        set_params(d->fx.damper, &k, sizeof(k)); d->sent_damper = dm;
    }
    long fr = to_di(d->cur_friction);
    if (fr != d->sent_friction && d->fx.friction) {
        DICONDITION k; ZeroMemory(&k, sizeof(k));
        k.lPositiveCoefficient = fr; k.lNegativeCoefficient = fr; k.dwPositiveSaturation = 10000; k.dwNegativeSaturation = 10000;
        set_params(d->fx.friction, &k, sizeof(k)); d->sent_friction = fr;
    }
    long vb = to_di(d->cur_vib);
    DWORD period = (DWORD)std::clamp(g_cmd.vib_ms, 8.0, 200.0) * 1000;
    if ((vb != d->sent_vib || (vb > 0 && period != d->sent_period)) && d->fx.sine) {
        DIPERIODIC p; ZeroMemory(&p, sizeof(p));
        p.dwMagnitude = (DWORD)vb; p.dwPeriod = period;
        set_params(d->fx.sine, &p, sizeof(p)); d->sent_vib = vb; d->sent_period = period;
    }
}

// ------------------------------------------------------------------ UDP
static SOCKET g_sock = INVALID_SOCKET;
static sockaddr_in g_game{};
static bool g_have_game = false;
static double g_last_hello = -1e9;
static bool g_quit = false;

static bool open_socket(int port) {
    WSADATA w;
    if (WSAStartup(MAKEWORD(2, 2), &w) != 0) return false;
    g_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (g_sock == INVALID_SOCKET) return false;
    BOOL off = FALSE; DWORD ret = 0;
    WSAIoctl(g_sock, SIO_UDP_CONNRESET, &off, sizeof(off), nullptr, 0, &ret, nullptr, nullptr);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons((u_short)port);
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    // a quick restart can find the previous bridge still holding the port: wait up to 3 s
    int tries = 0;
    while (bind(g_sock, (sockaddr*)&a, sizeof(a)) != 0) {
        if (++tries >= 60) { logf("[net] cannot bind 127.0.0.1:%d (already running?)", port); return false; }
        Sleep(50);
    }
    if (tries > 0) logf("[net] port %d was busy, bound after %d ms", port, tries * 50);
    u_long nb = 1;
    ioctlsocket(g_sock, FIONBIO, &nb);
    return true;
}

static void handle_packet(const char* text, const sockaddr_in& from) {
    double t = now_sec();
    char cmd[16] = {0};
    if (sscanf(text, "%15s", cmd) != 1) return;
    if (!strcmp(cmd, "hello")) {
        g_game = from; g_have_game = true; g_last_hello = t;
        logf("[net] game connected");
    } else if (!strcmp(cmd, "ffb")) {
        // ffb <dev> <const> <spring> <damper> <friction> <vib> <vib_ms> <gain>
        int dev; double c, s, d, f, v, vm, g;
        if (sscanf(text, "ffb %d %lf %lf %lf %lf %lf %lf %lf", &dev, &c, &s, &d, &f, &v, &vm, &g) == 8) {
            g_cmd.dev = dev; g_cmd.con = c; g_cmd.spr = s; g_cmd.dmp = d; g_cmd.fri = f; g_cmd.vib = v; g_cmd.vib_ms = vm; g_cmd.gain = g;
            g_cmd.last = t;
            g_game = from; g_have_game = true; g_last_hello = t;
        }
    } else if (!strcmp(cmd, "quit")) {
        g_quit = true;
    }
}

static void pump_udp() {
    char buf[512];
    for (int i = 0; i < 64; ++i) {
        sockaddr_in from{}; int fl = sizeof(from);
        int n = recvfrom(g_sock, buf, sizeof(buf) - 1, 0, (sockaddr*)&from, &fl);
        if (n <= 0) break;
        buf[n] = 0;
        handle_packet(buf, from);
    }
}

static void send_text(const std::string& s) {
    if (!g_have_game || g_sock == INVALID_SOCKET) return;
    sendto(g_sock, s.data(), (int)s.size(), 0, (sockaddr*)&g_game, sizeof(g_game));
}

static std::string devs_json() {
    std::string o = "{\"t\":\"devs\",\"d\":[";
    bool first = true;
    for (Dev* d : g_devs) {
        if (d->dead) continue;
        char b[512];
        std::string ax;
        for (int i = 0; i < NAXES; ++i) { ax += d->axis_present[i] ? '1' : '0'; if (i < NAXES - 1) ax += ','; }
        snprintf(b, sizeof(b), "%s{\"i\":%d,\"id\":\"%s\",\"n\":\"%s\",\"vid\":%d,\"pid\":%d,\"ffb\":%d,\"fx\":%d,\"nb\":%d,\"ax\":[%s]}",
                 first ? "" : ",", d->index, d->id.c_str(), json_escape(d->name).c_str(), d->vid, d->pid, d->ffb ? 1 : 0,
                 d->fx_ready ? 1 : 0, d->num_buttons, ax.c_str());
        o += b; first = false;
    }
    o += "]}";
    return o;
}

static std::string state_json(unsigned seq) {
    std::string o = "{\"t\":\"s\",\"q\":" + std::to_string(seq) + ",\"d\":[";
    bool first = true;
    for (Dev* d : g_devs) {
        if (d->dead || !d->acquired) continue;
        const DIJOYSTATE2& s = d->st;
        char b[400];
        std::string bits;
        int nb = std::min(d->num_buttons, 128);
        for (int i = 0; i < nb; i += 4) {
            int v = 0;
            for (int k = 0; k < 4 && i + k < nb; ++k) if (s.rgbButtons[i + k] & 0x80) v |= (1 << k);
            bits += "0123456789abcdef"[v];
        }
        int pov = (s.rgdwPOV[0] == 0xFFFFFFFF || LOWORD(s.rgdwPOV[0]) == 0xFFFF) ? -1 : (int)(s.rgdwPOV[0] / 100);
        snprintf(b, sizeof(b), "%s{\"i\":%d,\"a\":[%ld,%ld,%ld,%ld,%ld,%ld,%ld,%ld],\"b\":\"%s\",\"p\":%d}", first ? "" : ",", d->index,
                 s.lX, s.lY, s.lZ, s.lRx, s.lRy, s.lRz, s.rglSlider[0], s.rglSlider[1], bits.c_str(), pov);
        o += b; first = false;
    }
    o += "]}";
    return o;
}

// ------------------------------------------------------------------ main
static bool parent_alive(HANDLE h) {
    return !h || WaitForSingleObject(h, 0) == WAIT_TIMEOUT;
}

static HWND make_hidden_window() {
    HINSTANCE hi = GetModuleHandleW(nullptr);
    WNDCLASSW wc{};
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = hi;
    wc.lpszClassName = L"WheelBridgeWnd";
    RegisterClassW(&wc);
    return CreateWindowExW(WS_EX_TOOLWINDOW, L"WheelBridgeWnd", L"WheelBridge", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, hi, nullptr);
}

static void shutdown_all() {
    for (Dev* d : g_devs) close_device(d);
    if (g_di) { g_di->Release(); g_di = nullptr; }
}

static BOOL WINAPI on_ctrl(DWORD) { shutdown_all(); ExitProcess(0); return TRUE; }

static void cmd_list() {
    printf("DirectInput game controllers:\n");
    for (Dev* d : g_devs) {
        printf("  #%d  %s\n      id=%s  VID %04X  PID %04X  buttons=%d  FFB=%s\n      axes:", d->index, d->name.c_str(), d->id.c_str(), d->vid, d->pid,
               d->num_buttons, d->ffb ? "yes" : "no");
        for (int i = 0; i < NAXES; ++i) if (d->axis_present[i]) printf(" %s", AXIS_NAMES[i]);
        printf("\n");
        if (d->ffb) printf("      FFB axis offset=%lu  exclusive=%s  effects=%s\n", d->ffb_axis_ofs, d->exclusive ? "yes" : "NO", d->fx_ready ? "created" : "none");
    }
    if (g_devs.empty()) printf("  (none found - is the wheel / pedals connected and powered?)\n");
}

static void cmd_monitor(double secs) {
    printf("Monitoring %.0f s. Move the wheel / press pedals. Values: -32768..32767\n", secs);
    double t0 = now_sec();
    std::vector<DIJOYSTATE2> last(g_devs.size());
    for (auto& l : last) ZeroMemory(&l, sizeof(l));
    while (now_sec() - t0 < secs) {
        for (size_t i = 0; i < g_devs.size(); ++i) {
            Dev* d = g_devs[i];
            read_device(d);
            if (!d->acquired) continue;
            LONG* a = &d->st.lX; LONG* b = &last[i].lX;
            bool ch = false;
            for (int k = 0; k < 6; ++k) if (std::labs(a[k] - b[k]) > 600) ch = true;
            if (std::labs(d->st.rglSlider[0] - last[i].rglSlider[0]) > 600 || std::labs(d->st.rglSlider[1] - last[i].rglSlider[1]) > 600) ch = true;
            for (int k = 0; k < 32; ++k) if ((d->st.rgbButtons[k] & 0x80) != (last[i].rgbButtons[k] & 0x80)) ch = true;
            if (ch) {
                printf("#%d %-28s X=%6ld Y=%6ld Z=%6ld Rx=%6ld Ry=%6ld Rz=%6ld S0=%6ld S1=%6ld  btn:", d->index, d->name.c_str(), d->st.lX, d->st.lY, d->st.lZ,
                       d->st.lRx, d->st.lRy, d->st.lRz, d->st.rglSlider[0], d->st.rglSlider[1]);
                for (int k = 0; k < 32; ++k) if (d->st.rgbButtons[k] & 0x80) printf(" %d", k);
                printf("\n");
                last[i] = d->st;
            }
        }
        Sleep(10);
    }
}

static void ffb_step(Dev* d, const char* what, double con, double spr, double dmp, double vib, double secs) {
    printf("  %s\n", what); fflush(stdout);
    g_cmd.dev = d->index; g_cmd.con = con; g_cmd.spr = spr; g_cmd.dmp = dmp; g_cmd.fri = 0; g_cmd.vib = vib; g_cmd.vib_ms = 25; g_cmd.gain = 1.0;
    double t0 = now_sec(), prev = t0;
    while (now_sec() - t0 < secs) {
        double t = now_sec();
        g_cmd.last = t;
        g_ramp = 1.0;
        apply_ffb(d, t - prev, true);
        prev = t;
        Sleep(2);
    }
}

static void cmd_ffbtest(int idx) {
    Dev* d = nullptr;
    for (Dev* x : g_devs) if (x->index == idx) d = x;
    if (!d) { printf("no device #%d\n", idx); return; }
    if (!d->ffb || !d->exclusive || !d->fx_ready) { printf("device #%d (%s) has no usable force feedback (FFB=%d exclusive=%d effects=%d)\n", idx, d->name.c_str(), d->ffb, d->exclusive, d->fx_ready); return; }
    printf("FFB test on #%d %s. Keep your hands NEAR but not gripping tightly. Forces are low (cap 15%%).\n", idx, d->name.c_str());
    g_cap = 0.15;
    ffb_step(d, "1/4 centering spring (turn the wheel: it should pull back to the centre)", 0, 0.8, 0, 0, 4.0);
    ffb_step(d, "2/4 constant force to the RIGHT for 0.7 s", +0.8, 0, 0, 0, 0.7);
    ffb_step(d, "    ...pause", 0, 0, 0, 0, 0.8);
    ffb_step(d, "    constant force to the LEFT for 0.7 s", -0.8, 0, 0, 0, 0.7);
    ffb_step(d, "3/4 damper (the wheel should feel heavy / slow when turned)", 0, 0, 0.9, 0, 3.0);
    ffb_step(d, "4/4 vibration for 1.5 s", 0, 0, 0, 0.8, 1.5);
    ffb_step(d, "stopping", 0, 0, 0, 0, 0.5);
    printf("done.\n");
}

int main(int argc, char** argv) {
    std::string mode = "serve";
    int port = 49321, parent_pid = 0, idx = 0;
    double secs = 20;
    std::string logpath;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&](const char* def) -> const char* { return (i + 1 < argc) ? argv[++i] : def; };
        if (a == "--list") mode = "list";
        else if (a == "--monitor") { mode = "monitor"; if (i + 1 < argc && argv[i + 1][0] != '-') secs = atof(argv[++i]); }
        else if (a == "--ffbtest") { mode = "ffbtest"; idx = atoi(next("0")); }
        else if (a == "--serve") mode = "serve";
        else if (a == "--fake") g_fake = true;
        else if (a == "--port") port = atoi(next("49321"));
        else if (a == "--parent") parent_pid = atoi(next("0"));
        else if (a == "--cap") g_cap = std::clamp(atof(next("1")), 0.0, 1.0);
        else if (a == "--log") logpath = next("");
    }
    if (!logpath.empty()) g_log = fopen(logpath.c_str(), "w");
    timeBeginPeriod(1);
    SetConsoleCtrlHandler(on_ctrl, TRUE);
    g_hwnd = make_hidden_window();
    g_fake_t0 = now_sec();

    // serve: take the port first (so we never fight over the wheel while waiting for an old bridge)
    if (mode == "serve" && !open_socket(port)) return 2;

    if (g_fake) make_fake_device();
    else {
        if (FAILED(DirectInput8Create(GetModuleHandleW(nullptr), DIRECTINPUT_VERSION, IID_IDirectInput8W, (void**)&g_di, nullptr))) {
            logf("[error] DirectInput8Create failed");
            return 1;
        }
        rescan_devices(true);
    }

    if (mode == "list") { cmd_list(); shutdown_all(); return 0; }
    if (mode == "monitor") { cmd_list(); cmd_monitor(secs); shutdown_all(); return 0; }
    if (mode == "ffbtest") { cmd_ffbtest(idx); shutdown_all(); return 0; }

    HANDLE parent = parent_pid ? OpenProcess(SYNCHRONIZE, FALSE, (DWORD)parent_pid) : nullptr;
    logf("[bridge] serving on 127.0.0.1:%d  (%zu device%s)%s", port, g_devs.size(), g_devs.size() == 1 ? "" : "s", g_fake ? "  [FAKE]" : "");

    double t_prev = now_sec(), t_state = 0, t_devs = 0, t_scan = now_sec(), t_log = 0;
    unsigned seq = 0;
    while (parent_alive(parent) && !g_quit) {
        double t = now_sec();
        double dt = std::clamp(t - t_prev, 0.0005, 0.05);
        t_prev = t;
        pump_udp();
        bool game_alive = g_have_game && (t - g_last_hello) < 2.0;
        bool ffb_active = (t - g_cmd.last) < 0.3;
        if (ffb_active) g_ramp = std::min(1.0, g_ramp + dt / 1.0); else g_ramp = 0.0;
        for (Dev* d : g_devs) {
            read_device(d);
            if (d->ffb) apply_ffb(d, dt, ffb_active);
        }
        if (game_alive && t - t_state >= 0.005) {
            t_state = t;
            send_text(state_json(seq++));
        }
        if (game_alive && t - t_devs >= 1.0) { t_devs = t; send_text(devs_json()); }
        if (!g_fake && t - t_scan >= 2.0) { t_scan = t; rescan_devices(false); }
        if (g_fake && t - t_log >= 1.0) {
            t_log = t;
            if (ffb_active) logf("[fake] ffb dev=%d con=%.2f spr=%.2f dmp=%.2f fri=%.2f vib=%.2f gain=%.2f ramp=%.2f", g_cmd.dev, g_cmd.con, g_cmd.spr, g_cmd.dmp, g_cmd.fri, g_cmd.vib, g_cmd.gain, g_ramp);
        }
        Sleep(2);
    }
    logf("[bridge] parent gone, exiting");
    shutdown_all();
    return 0;
}
