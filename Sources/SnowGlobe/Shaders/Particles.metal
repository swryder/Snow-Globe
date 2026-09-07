#include <metal_stdlib>
using namespace metal;

// Mirrors Particle and Uniforms in ParticleRenderer.swift. Four-float fields
// keep the CPU/GPU layout explicit, including on a future iOS host.
struct Particle {
    float4 position;   // xyz, visibility
    float4 velocity;   // xyz, collision afterglow
    float4 orbit;      // phase, radial seed, vertical seed, current index
    float4 appearance; // random seed, energy, size seed, speech phase (-100 means settled)
};
struct Uniforms {
    float4 timing;     // time, fixed dt, smoothed activity, smoothed dark mode
    float4 viewport;   // pixels wide, pixels high, backing scale, EDR headroom
    uint4 counts;     // particle count, grid side, cell capacity, latest history sample
    float4 motion;    // integrated flow time, motion clock rate, spatial fullness, effective disc blend
    float4 controls;  // particle density multiplier, particle size multiplier, trail length, activity sparkle
    float4 orientation; // integrated current-frame quaternion, xyz imaginary / w real
    float4 response; // effort boost, speech history cursor, speech expression, history span
    float4 speech; // audio envelope, syllable accent, speech time, ribbon presence
    float4 speechLight; // flash gain, fast loudness envelope, fast onset envelope, speech presence
    float4 speechMode; // live waveform blend, live history span, PCM data available, PCM sample count
    float4 connection; // eased connection/lift, requested connected state, transparent background, reserved
    float4 optics; // glass strength, glass opacity, live backdrop available, reserved
    float4 backdropUV; // viewport origin and size in normalized backdrop coordinates
};

constant float TAU = 6.28318530718;
constant uint GRID = 32;
constant uint CELL_CAPACITY = 32;
constant uint HISTORY_SAMPLES = 256;
constant uint TRAIL_SEGMENTS = 24;
constant uint SPEECH_SAMPLES = 480;

float hash(float n) { return fract(sin(n * 127.1 + 311.7) * 43758.5453); }
// Quintic interpolation gives continuous velocity and acceleration. Slowly
// changing random values create drift without a repeating sine-wave cadence.
float drift(float x) {
    float cell = floor(x), f = fract(x);
    float blend = f*f*f*(f*(f*6.0-15.0)+10.0);
    return mix(hash(cell),hash(cell+1.0),blend)*2.0-1.0;
}

float3 curlLayer(float3 q, float phase) {
    // Curl of A = (sin(y+phase)cos(z), sin(z+phase)cos(x),
    //              sin(x+phase)cos(y)). Nearby particles share these eddies.
    return float3(-sin(q.x+phase)*sin(q.y)-cos(q.z+phase)*cos(q.x),
                  -sin(q.y+phase)*sin(q.z)-cos(q.x+phase)*cos(q.y),
                  -sin(q.z+phase)*sin(q.x)-cos(q.y+phase)*cos(q.z));
}

float3 eddies(float3 position, float time) {
    float3 offset = float3(drift(time*0.11+31),drift(time*0.09+79),drift(time*0.13+137));
    return curlLayer(position*3.7+offset,time*0.16)*0.65
         + curlLayer(position*8.1-offset*0.7,-time*0.21)*0.20;
}

float3 rotateX(float3 v, float a) {
    float s = sin(a), c = cos(a);
    return float3(v.x, c*v.y-s*v.z, s*v.y+c*v.z);
}
float3 rotateZ(float3 v, float a) {
    float s = sin(a), c = cos(a);
    return float3(c*v.x-s*v.y, s*v.x+c*v.y, v.z);
}
float3 orientCurrent(float3 v, constant Uniforms &u) {
    // Rotate the guiding flow, not the rendered particles. Inertia, eddies and
    // the glass still determine how each particle follows the moving plane.
    float3 q = u.orientation.xyz;
    return v + 2.0*cross(q,cross(q,v)+u.orientation.w*v);
}
float ringPresence(uint ring, float activity) {
    if (ring == 0) return 1.0;
    if (ring == 1) return smoothstep(0.32,0.50,activity);
    float start = 0.46 + float(ring-1)*0.085;
    return smoothstep(start, start+0.22, activity);
}

float2 currentTilt(float ring, float activity, float time) {
    float2 tilt = float2(0.20,0.015*sin(time*0.13));
    if (ring < 1.5) {
        // Share the primary current's slow wandering so the second stays
        // roughly perpendicular. Small independent drift keeps it alive.
        tilt.x += (0.045+activity*0.19)*drift(time*0.16+17);
        tilt.y += (0.035+activity*0.23)*drift(time*0.12+91);
        if (ring > 0.5) {
            tilt.x += TAU*0.25+0.045*drift(time*0.17+137);
            tilt.y += 0.045*drift(time*0.14+163);
        }
        return tilt;
    }
    tilt.x = ring == 2 ? -0.72 : ring == 3 ? 1.10 : -1.05;
    tilt.y = ring == 2 ? 0.50 : ring == 3 ? 0.70 : -0.67;
    tilt.x += (0.045+activity*0.19)*drift(time*0.16+ring*21.7+17);
    tilt.y += (0.035+activity*0.23)*drift(time*0.12+ring*17.3+91);
    return tilt;
}

float3 currentCenter(float ring, float activity, float time) {
    float expansion = smoothstep(0.02,0.55,activity);
    float y = ring < 0.5 ? mix(-0.55,-0.02,expansion) : (ring-2.5)*0.08;
    return float3(0,y,0)
         + float3(drift(time*0.13+ring*17+31),drift(time*0.11+ring*23+61),0)
         * (0.013+0.030*activity);
}

float3 currentPoint(Particle p, float phase, constant Uniforms &u) {
    float a = u.motion.z;
    float t = u.motion.x;
    float ring = p.orbit.w;
    float seed = p.appearance.x;
    float expansion = smoothstep(0.02, 0.75, a);
    float radius = mix(0.47, 0.84, expansion);
    float2 tilt = currentTilt(ring,a,t);
    if (ring > 0.5) {
        radius = 0.80 - 0.035 * cos(ring*2.0);
    }
    radius *= 1.0+(0.035+0.035*a)*drift(t*0.19+ring*19+57);

    // A bell-shaped cross-section feathers into wisps instead of terminating
    // at a uniformly populated tube edge. Its lanes keep migrating over time.
    float spread = sqrt(-2.0*log(max(0.012,p.orbit.y)));
    float2 section = spread*float2(cos(p.orbit.z*TAU),sin(p.orbit.z*TAU));
    float lane = t*(0.14+seed*0.12)+seed*37.0;
    float thickness = mix(0.037,0.155,smoothstep(0.0,0.85,a));
    float swell = 1.0+0.32*sin(phase*2.0+drift(t*0.15+23+ring)*2.0);
    float r = radius + section.x*thickness*swell;
    r += (0.013+0.040*a)*drift(lane+81);
    r += (0.016+0.048*a)*sin(2.0*phase+drift(t*0.17+ring*11+9)*2.0);
    r += (0.009+0.024*a)*sin(3.0*phase+drift(t*0.13+ring*17+44)*3.0);
    float height = section.y*thickness*1.05*swell;
    height += (0.010+0.035*a)*drift(lane+177);
    height += (0.015+0.051*a)*sin(phase*2.0+drift(t*0.14+ring*23+73)*2.0);
    height += (0.006+0.020*a)*sin(phase*3.0+drift(t*0.18+ring*19+101)*3.0);
    if (u.motion.w > 0) {
        // Square-root sampling distributes particles across the disc's area,
        // including the center, without concentrating them into a bright knot.
        float areaSeed = hash(seed*403.0+101.0);
        // The glass sets the disc's reach, even at rest. Outer lanes aim
        // slightly through it so the wall, rather than a smaller invisible
        // orbit, bends their motion. The inner area remains populated.
        float discRadius = 1.06*sqrt(max(0.002,areaSeed));
        discRadius += section.x*thickness*0.25+(0.008+0.015*a)*drift(lane+81);
        r = mix(r,max(0.025,discRadius),u.motion.w);
    }
    float3 q = float3(r*cos(phase), height, r*sin(phase));
    q = orientCurrent(rotateZ(rotateX(q, tilt.x), tilt.y),u);
    q += currentCenter(ring,a,t);
    return q;
}

// Speech enters behind the left shoulder; older syllables cross the front. Samples
// come from the audio player's timeline, with a small spatial filter to soften
// 10 ms envelope edges without inventing a periodic carrier wave.
float2 speechAt(float age, constant float2 *samples, constant Uniforms &u) {
    float lookback = clamp(age/u.timing.y,0.0,float(SPEECH_SAMPLES-4));
    uint whole = uint(lookback);
    float f = fract(lookback);
    uint cursor = uint(u.response.y);
    float2 a = samples[(cursor+SPEECH_SAMPLES-whole)%SPEECH_SAMPLES];
    float2 b = samples[(cursor+SPEECH_SAMPLES-whole-1)%SPEECH_SAMPLES];
    float2 c = samples[(cursor+SPEECH_SAMPLES-whole-2)%SPEECH_SAMPLES];
    return mix(a*0.65+b*0.35,b*0.65+c*0.35,f*f*(3.0-2.0*f));
}

float speechAge(float phase, constant Uniforms &u) {
    float progress = (cos(phase)+1.0)*0.5;
    float age = 0.35+progress*u.response.w;
    // The newest sound begins on the rear-left arc, before the visible front
    // sweep. By the time it rounds the shoulder the syllable is established.
    float normalized = fmod(phase+TAU,TAU);
    if (normalized > TAU*0.5 && normalized < TAU*0.5+0.55) {
        age = 0.35*(1.0-(normalized-TAU*0.5)/0.55);
    }
    return age;
}

float speechFacing(float phase) {
    // Release amplitude behind the glass so the returning traces do not
    // compete with the front waveform or draw duplicate peaks across it.
    return smoothstep(-0.50,0.20,sin(phase));
}

float liveWaveformWeight(constant Uniforms &u) {
    return u.speechMode.x*u.speechLight.w*smoothstep(0.0,0.10,u.response.z);
}

float liveWaveformAge(uint id, constant Uniforms &u) {
    // New speech enters at the left; increasing age carries its shape right.
    return hash(float(id)+3571.0)*u.speechMode.y;
}

float3 liveWaveformPosition(uint id, constant float2 *samples, constant float2 *waveform, constant Uniforms &u) {
    // Stable horizontal stations sample only the most recent audio. No phase
    // clock or scrolling particle transport: all ongoing motion is vertical.
    float x = (hash(float(id)+3571.0)*2.0-1.0)*0.84;
    float z = 0.16+0.025*(hash(float(id)+3617.0)-0.5);
    float age = liveWaveformAge(id,u);
    float amplitude = min(1.0,speechAt(age,samples,u).x*u.response.z);
    float prior = min(1.0,speechAt(age+0.025,samples,u).x*u.response.z);
    float room = sqrt(max(0.001,0.855*0.855-x*x-z*z));
    uint band = id%3;
    float y = band == 0 ? (0.02+0.86*amplitude)*room
            : band == 1 ? -(0.02+0.86*amplitude)*room
            : (amplitude-prior)*0.35*room;
    if (u.speechMode.z > 0.5) {
        float station = (1.0-hash(float(id)+3571.0))*(u.speechMode.w-1.0);
        uint index = uint(station);
        float2 peaks = mix(waveform[index],waveform[min(index+1,uint(u.speechMode.w)-1)],fract(station));
        peaks = clamp(peaks*u.response.z,-0.95,0.95);
        // Most particles trace the signed outlines; some fill between them.
        // This is one detailed waveform around zero, not three broad ribbons.
        float lane = smoothstep(0.38,0.62,hash(float(id)+3727.0));
        y = mix(peaks.x,peaks.y,lane)*room;
    }
    y += 0.004*(hash(float(id)+3671.0)-0.5)
       + 0.002*drift(u.speech.z*0.8+float(id)*0.73);
    return float3(x,y,z);
}

float3 speechRibbon(uint id, float phase, constant float2 *samples, constant Uniforms &u) {
    uint band = id%3;
    float seed = hash(float(id)+2219.0);
    float x = 0.92*cos(phase);
    float age = speechAge(phase,u);
    float facing = speechFacing(phase);
    float amplitude = speechAt(age,samples,u).x*u.response.z*facing;
    float prior = speechAt(age+0.12,samples,u).x*u.response.z*facing;
    float edge = sqrt(max(0.025,1.0-x*x/(0.95*0.95)));
    float y = band == 0 ? 0.105+0.47*amplitude
            : band == 1 ? -0.105-0.47*amplitude
            : (amplitude-prior)*0.45;
    // A deeper loop brings the voiced arc toward the viewer and carries the
    // return around the rear. Broad central room lets peaks develop fully.
    float z = sin(phase)*0.48-0.06+(float(band)-1.0)*0.08;
    z += amplitude*(seed-0.5)*0.08;
    float softness = 0.028+0.020*hash(float(id)+2381.0);
    y = y*edge + softness*drift(u.speech.z*0.65+seed*137.0);
    z += softness*drift(u.speech.z*0.48+seed*191.0+53.0);
    return float3(x,y,z);
}

// Separate admission seeds preserve the energy palette when density changes.
// The first bank is the original population; the second supplies 100–200%.
float densityAdmission(uint id, float density) {
    // A coprime integer permutation assigns a unique rank to every particle.
    // This keeps tiny count limits exact, with one softly entering particle
    // between integer budgets. Separate banks preserve the original 16,800.
    uint rank = (id%16800*7919+104729)%16800+(id/16800)*16800;
    float budget = clamp(density*16800.0,10.0,33600.0);
    return smoothstep(float(rank),float(rank+1),budget);
}

kernel void initializeParticles(device Particle *particles [[buffer(0)]],
                               constant Uniforms &u [[buffer(1)]],
                               device float4 *history [[buffer(2)]],
                               uint id [[thread_position_in_grid]]) {
    if (id >= u.counts.x) return;
    Particle p;
    uint laneID = id % 16800;
    uint ring = laneID < 7200 ? 0 : 1 + (laneID-7200)/2400;
    p.orbit = float4(hash(float(id)+1)*TAU, hash(float(id)+11), hash(float(id)+23), float(ring));
    p.appearance = float4(hash(float(id)+47), 0, hash(float(id)+89), 0);
    p.position = float4(currentPoint(p, p.orbit.x, u), ring == 0 ? smoothstep(p.appearance.x-0.035,p.appearance.x+0.035,0.33) : 0.0);
    p.position.w *= densityAdmission(id,u.controls.x);
    p.velocity = float4(0);
    particles[id] = p;
    for (uint sample=0; sample<HISTORY_SAMPLES; ++sample) {
        history[sample*u.counts.x+id] = p.position;
    }
}

float settledHeight(float2 horizontal, float layer) {
    float bottom = -sqrt(max(0.0,0.94*0.94-dot(horizontal,horizontal)));
    return bottom+layer*max(0.0,-0.74-bottom);
}

float3 settledPosition(uint id) {
    float radius = 0.50*sqrt(hash(float(id)+4001.0));
    float angle = TAU*hash(float(id)+4013.0);
    float2 horizontal = radius*float2(cos(angle),sin(angle));
    return float3(horizontal.x,settledHeight(horizontal,hash(float(id)+4027.0)),horizontal.y);
}

kernel void integrateParticles(device const Particle *source [[buffer(0)]],
                               device Particle *destination [[buffer(1)]],
                               constant Uniforms &u [[buffer(2)]],
                               device float4 *history [[buffer(3)]],
                               constant float2 *speechSamples [[buffer(4)]],
                               constant float2 *waveform [[buffer(5)]],
                               uint id [[thread_position_in_grid]]) {
    if (id >= u.counts.x) return;
    Particle p = source[id];
    // Fullness and kinetic energy are independent. Idle uses a cloud shaped
    // like the former 40% state, advancing on a much slower flow clock.
    float realDT = u.timing.y;
    if (u.connection.y < 0.5) {
        // Gravity replaces the currents. Preserve admission so every particle
        // that was visible at disconnect reaches the bed instead of fading out.
        // A sleeping grain stays exactly where it settled. This avoids tiny
        // perpetual slides caused by gravity against the curved glass.
        if (p.appearance.w < -50.0) {
            p.velocity = float4(0);
            p.appearance.y *= exp(-realDT*3.0);
            destination[id] = p;
            history[u.counts.w*u.counts.x+id] = p.position;
            return;
        }
        float rate = max(0.05,u.motion.y);
        float3 velocity = p.velocity.xyz*rate;
        float3 rest = settledPosition(id);
        // Build the soft bed as snow arrives; do not push particles already
        // near the glass instantly upward into an invisible preformed pile.
        float layer = hash(float(id)+4027.0)*(1.0-smoothstep(0.10,0.70,u.connection.x));
        float bed = settledHeight(p.position.xz,layer);
        bool grounded = p.position.y <= bed+0.006;
        float pull = grounded ? 12.0 : 2.0;
        float drag = grounded ? 7.0 : 1.5;
        velocity.xz += (rest.xz-p.position.xz)*pull*realDT;
        velocity.xz *= exp(-drag*realDT);
        velocity.y = (velocity.y-2.4*realDT)*exp(-0.6*realDT);
        p.position.xyz += velocity*realDT;
        float radius = length(p.position.xyz);
        if (radius > 0.94) {
            float3 normal = p.position.xyz/radius;
            p.position.xyz = normal*0.94;
            velocity -= normal*max(0.0,dot(velocity,normal));
        }
        bed = settledHeight(p.position.xz,layer);
        if (p.position.y < bed) { p.position.y = bed; velocity.y = max(0.0,velocity.y)*0.08; }
        radius = length(p.position.xyz);
        if (radius > 0.94) { p.position.xyz *= 0.94/radius; }
        if (u.connection.x < 0.02 && p.position.y < -0.73
            && abs(p.position.y-bed) < 0.01 && length(velocity) < 0.02) {
            p.appearance.w = -100.0;
            velocity = float3(0);
        }
        p.velocity = float4(velocity/rate,p.velocity.w*exp(-realDT*8.0));
        p.appearance.y *= exp(-realDT*3.0);
        destination[id] = p;
        history[u.counts.w*u.counts.x+id] = p.position;
        return;
    }
    if (p.appearance.w < -50.0) {
        p.appearance.w = atan2((p.position.z+0.06)/0.48,p.position.x/0.92);
    }
    float dt = realDT*u.motion.y, a = u.motion.z, t = u.motion.x;
    float activity = u.timing.z;
    uint ring = uint(p.orbit.w);
    float seed = p.appearance.x;
    float direction = (ring == 1 || ring == 4) ? -1.0 : 1.0;
    float speed = (0.13 + 1.48*pow(a, 1.6)) * direction;
    speed *= (0.82+0.31*seed)*(1.0+float(ring)*0.07);
    // Shared local surges bunch and release the flow; independent drift lets
    // particles overtake each other instead of keeping a fixed formation.
    speed *= 1.0+0.22*drift(t*0.21+float(ring)*31+53)
                +0.17*sin(p.orbit.x*2.0+drift(t*0.17+41)*2.0)
                +0.14*drift(t*0.28+seed*113+97);
    float phase = p.orbit.x;
    p.orbit.x = fmod(phase + speed*dt + TAU, TAU);
    float3 target = currentPoint(p, p.orbit.x, u);
    float3 ahead = currentPoint(p,p.orbit.x+0.025,u);
    float3 behind = currentPoint(p,p.orbit.x-0.025,u);
    float3 tangent = (ahead-behind)*20.0*speed;
    float3 curvature = (ahead-2.0*target+behind)*1600.0*speed*speed;
    float3 along = normalize(ahead-behind);
    float3 error = target-p.position.xyz;
    float3 crossCurrent = error-along*dot(error,along)*0.78;
    float entrainment = 0.82+0.32*drift(t*0.15+seed*71+113);
    float3 orbitalAcceleration = crossCurrent*mix(11.0,17.0,a)*entrainment
                               + (tangent-p.velocity.xyz)*mix(3.6,4.8,a)
                               + curvature*0.82
                               + eddies(p.position.xyz,t)*(0.045+0.36*a*a);

    // As energy arrives, particles leave their low orbital guide and are
    // carried by broad inertial flow. This field supplies forward motion, not
    // a prescribed circle: the glass supplies the force that turns the stream.
    float2 tilt = currentTilt(float(ring),a,t);
    float3 axis = orientCurrent(rotateZ(rotateX(float3(0,1,0),tilt.x),tilt.y),u);
    float3 center = currentCenter(float(ring),a,t);
    float3 fromCenter = p.position.xyz-center;
    float3 circulation = cross(fromCenter,axis)*direction;
    float3 flowVelocity = circulation/max(0.03,length(circulation))*abs(speed)*(0.55+0.25*a);
    // A minority of the main stream gets lifted into slow, suspended wisps
    // early, so the upper volume wakes up before the additional currents do.
    float suspension = smoothstep(0.02,0.30,a)
                     * (1.0-smoothstep(0.20,0.40,hash(seed*211.0+51.0)));
    float loft = ring == 0 ? suspension*(0.45+0.35*drift(t*0.12+seed*41+75)) : 0.0;
    float layerOffset = dot(p.position.xyz-target,axis)-loft;
    float3 pressureDirection = fromCenter/max(0.05,length(fromCenter));
    float pressure = 0.06+(0.18+0.25*a)*drift(t*0.22+dot(p.position.xyz,float3(1.7,2.1,0.5))+float(ring)*31+59);
    float3 fluidAcceleration = (flowVelocity-p.velocity.xyz)*1.65
                             - axis*layerOffset*(0.65+seed*0.45)
                             + eddies(p.position.xyz,t)*(0.20+0.44*a)
                             + pressureDirection*pressure;
    // Traveling return plumes peel portions of the wall flow back into the
    // volume. Without this turnover, sustained activity settles into a shell.
    float returnPlume = smoothstep(0.05,0.65,
        drift(t*0.23+float(ring)*7.0+dot(p.position.xyz,float3(1.1,0.6,-0.4))+33));
    // Keep a small population in the return flow between traveling plumes,
    // so changing the motion clock cannot leave the entire cloud on the wall.
    float returning = 1.0-smoothstep(0.14,0.24,hash(seed*331.0+173.0));
    returnPlume = max(returnPlume,0.85*returning);
    fluidAcceleration -= pressureDirection*returnPlume*(1.4+2.2*a)
                       * (0.4+0.6*hash(seed*177+83))
                       * smoothstep(0.30,0.72,length(fromCenter));
    float releaseSeed = hash(seed*151.0+19.0);
    float release = smoothstep(releaseSeed*0.38,releaseSeed*0.38+0.24,a)
                  * smoothstep(0.015,0.10,a);
    release = max(release,suspension);
    float3 acceleration = mix(orbitalAcceleration,fluidAcceleration,release);
    if (u.motion.w > 0) {
        float3 radial = fromCenter-axis*dot(fromCenter,axis);
        float radialDistance = length(radial);
        float3 radialDirection = radial/max(0.025,radialDistance);
        // Intersect this particle's actual layer with the sphere. Lofted
        // wisps and tilted layers therefore reach the same curved boundary.
        float3 layerCenter = center+axis*dot(fromCenter,axis);
        float projectedCenter = dot(layerCenter,radialDirection);
        float wallRadius = max(0.08,-projectedCenter+sqrt(max(0.0,
            projectedCenter*projectedCenter+0.94*0.94-dot(layerCenter,layerCenter))));
        float areaSeed = hash(seed*403.0+101.0);
        float breathing = 1.13+0.045*drift(t*0.19+seed*37.0+81);
        float targetRadius = wallRadius*breathing*sqrt(max(0.002,areaSeed));
        // Inner lanes turn at the same gentle angular cadence. A loose radial
        // guide supplies their centripetal force, so the center stays populated
        // instead of being emptied by the wall-following flow.
        float3 discVelocity = flowVelocity*min(1.0,radialDistance/0.82);
        float centripetal = dot(discVelocity,discVelocity)/max(0.08,radialDistance);
        float3 discAcceleration = (discVelocity-p.velocity.xyz)*3.5
                                + radialDirection*((targetRadius-radialDistance)*7.0-centripetal)
                                - axis*layerOffset*0.95
                                + eddies(p.position.xyz,t)*(0.11+0.30*a);
        acceleration = mix(acceleration,discAcceleration,u.motion.w);
    }
    // Loosely entrain the existing particles in three audio-history ribbons.
    // Only forces change: heads and their true path histories never teleport.
    if (u.speech.w < 0.005) {
        p.appearance.w = atan2((p.position.z+0.06)/0.48,p.position.x/0.92);
    }
    if (u.speech.w > 0.001) {
        float phase = p.appearance.w;
        // Approximately even path speed keeps the thin loop's ends from
        // accumulating bright knots as the particles turn behind the globe.
        float arcLength = length(float2(0.92*sin(phase),0.48*cos(phase)));
        float cadence = min(2.0,(0.60+0.08*hash(float(id)+2551.0))/max(0.48,arcLength));
        phase -= realDT*cadence*(1.0-u.speechMode.x);
        p.appearance.w = fmod(phase+TAU,TAU);
        float3 ribbon = speechRibbon(id,phase,speechSamples,u);
        float3 travel = float3(0.92*sin(phase)*cadence,0,-0.48*cos(phase)*cadence);
        float rate = max(0.05,u.motion.y);
        float3 ribbonAcceleration = ((ribbon-p.position.xyz)*52.0
                                  + (travel-p.velocity.xyz*rate)*11.0)/(rate*rate);
        ribbonAcceleration += eddies(p.position.xyz,t)*0.14;
        float participation = mix(0.84,0.96,hash(float(id)+2671.0));
        acceleration = mix(acceleration,ribbonAcceleration,u.speech.w*participation);
    }
    float liveWeight = liveWaveformWeight(u);
    if (liveWeight > 0.00001) {
        float3 target = liveWaveformPosition(id,speechSamples,waveform,u);
        float rate = max(0.05,u.motion.y);
        // Soft layout acquisition in x/z; fast, critically damped response in
        // y. Real-time coefficients keep speech independent of the effort clock.
        float3 liveAcceleration = ((target-p.position.xyz)*float3(64,6400,64)
                                - p.velocity.xyz*rate*float3(16,160,16))/(rate*rate);
        acceleration = mix(acceleration,liveAcceleration,liveWeight);
    }
    float distanceBefore = length(p.position.xyz);
    // Reconnecting provides a brief upward lift, then the existing idle
    // currents take over. Keep the current positions and trail history intact.
    float rate = max(0.05,u.motion.y);
    acceleration.y += 3.5*(1.0-u.connection.x)/(rate*rate);
    float3 wallNormal = p.position.xyz/max(0.001,distanceBefore);
    float wallPressure = smoothstep(0.87,0.94,distanceBefore);
    acceleration -= wallNormal*wallPressure
                  *(8.0*wallPressure+max(0.0,dot(p.velocity.xyz,wallNormal))*5.0);
    p.velocity.xyz += acceleration*dt;
    p.position.xyz += p.velocity.xyz*dt;
    // Keep tangential momentum at contact: particles slide along the glass
    // and peel away with the eddies, with only a very small normal rebound.
    float distance = length(p.position.xyz);
    if (distance > 0.94) {
        float3 normal = p.position.xyz / distance;
        p.position.xyz = normal*0.94;
        p.velocity.xyz -= normal*max(0.0, dot(p.velocity.xyz, normal))*1.08;
    }
    float presence = ringPresence(ring, activity);
    // A stable seed orders admission into each stream, avoiding global recoloring.
    float energy = smoothstep(seed*0.86, seed*0.86+0.14, activity);
    energy *= smoothstep(0.015, 0.12, activity);
    // Keep colors and current admission responsive to the same effort swing,
    // rather than adding a second long visual delay after the flow accelerates.
    p.appearance.y += (energy-p.appearance.y)*(1.0-exp(-realDT*(2.6+6.0*u.response.x)));
    float density = ring == 0 ? mix(0.33, 1.0, smoothstep(0.02, 0.70, activity)) : 1.0;
    float visibility = smoothstep(seed-0.035, seed+0.035, density)*presence
                     *densityAdmission(id,u.controls.x);
    p.position.w += (visibility-p.position.w)*(1.0-exp(-realDT*(3.0+6.0*u.response.x)));
    p.velocity.w *= exp(-realDT*(3.8+seed*2.2));
    destination[id] = p;
    history[u.counts.w*u.counts.x+id] = p.position;
}

uint gridIndex(int3 c) { return uint(c.x + c.y*int(GRID) + c.z*int(GRID*GRID)); }
int3 cellFor(float3 p) { return clamp(int3((p+1.0)*0.5*float(GRID)), int3(0), int3(GRID-1)); }

kernel void buildGrid(device const Particle *particles [[buffer(0)]],
                      device atomic_uint *counts [[buffer(1)]],
                      device uint *indices [[buffer(2)]],
                      constant Uniforms &u [[buffer(3)]],
                      uint id [[thread_position_in_grid]]) {
    if (id >= u.counts.x || particles[id].position.w < 0.2) return;
    uint cell = gridIndex(cellFor(particles[id].position.xyz));
    uint slot = atomic_fetch_add_explicit(&counts[cell], 1, memory_order_relaxed);
    if (slot < CELL_CAPACITY) indices[cell*CELL_CAPACITY+slot] = id;
}

kernel void collideParticles(device const Particle *source [[buffer(0)]],
                             device Particle *destination [[buffer(1)]],
                             device const uint *counts [[buffer(2)]],
                             device const uint *indices [[buffer(3)]],
                             constant Uniforms &u [[buffer(4)]],
                             uint id [[thread_position_in_grid]]) {
    if (id >= u.counts.x) return;
    Particle p = source[id];
    float strength = smoothstep(0.79, 0.99, u.timing.z)*(1.0-liveWaveformWeight(u));
    float3 impulse = 0;
    float flash = 0;
    if (p.position.w > 0.2 && strength > 0) {
        int3 cell = cellFor(p.position.xyz);
        for (int z=-1; z<=1; ++z) for (int y=-1; y<=1; ++y) for (int x=-1; x<=1; ++x) {
            int3 c = cell+int3(x,y,z);
            if (any(c < 0) || any(c >= int(GRID))) continue;
            uint index = gridIndex(c);
            uint count = min(counts[index], CELL_CAPACITY);
            for (uint n=0; n<count; ++n) {
                uint other = indices[index*CELL_CAPACITY+n];
                if (other == id) continue;
                Particle q = source[other];
                if (q.orbit.w == p.orbit.w) continue;
                float3 delta = p.position.xyz-q.position.xyz;
                float d2 = dot(delta,delta);
                if (d2 > 0.000001 && d2 < 0.000100) {
                    float d = sqrt(d2);
                    float3 normal = delta/d;
                    float closingSpeed = max(0.0, -dot(p.velocity.xyz-q.velocity.xyz,normal));
                    float impact = (1.0-d/0.010)*max(0.0,closingSpeed-0.18)*strength;
                    impulse += normal*impact*0.32;
                    flash = max(flash, impact*1.4);
                }
            }
        }
        float magnitude = length(impulse);
        if (magnitude > 0.45) impulse *= 0.45/magnitude;
        p.velocity.xyz += impulse;
        p.velocity.w = max(p.velocity.w, min(flash, 1.0));
    }
    destination[id] = p;
}

struct ScreenVertex { float4 position [[position]]; float2 uv; };
vertex ScreenVertex fullscreenVertex(uint id [[vertex_id]]) {
    float2 p = float2(id == 2 ? 3.0 : -1.0, id == 1 ? 3.0 : -1.0);
    return { float4(p,0,1), p };
}

float2 globeCoordinates(float2 ndc, constant Uniforms &u) {
    return ndc*u.viewport.xy/(min(u.viewport.x,u.viewport.y)*0.89);
}
float3 backgroundColor(float dark) {
    // Linear Display P3 values, matching the SwiftUI surround after conversion.
    return mix(float3(0.869,0.880,0.901), float3(0.00163,0.00224,0.00385), dark);
}

float globeCoverage(float2 pixelPosition, constant Uniforms &u) {
    if (u.connection.z < 0.5) return 1.0;
    float2 ndc = pixelPosition/u.viewport.xy*2.0-1.0;
    float radius = length(globeCoordinates(ndc,u));
    return 1.0-smoothstep(0.995,1.005,radius);
}

float4 globeSurface(float2 ndc, float2 pixelPosition, constant Uniforms &u) {
    float2 p = globeCoordinates(ndc,u);
    float r = length(p);
    float dark = u.timing.w;
    float a = u.timing.z;
    float3 background = backgroundColor(dark);
    float inside = 1.0-smoothstep(0.995,1.005,r);
    float depth = sqrt(max(0.0,1.0-r*r));
    float3 tint = mix(float3(-0.045,-0.033,-0.010),float3(0.004,0.009,0.016),dark);
    float3 color = background + tint*inside*(0.25+0.75*depth);
    if (dark < 0.9999) {
        // A steady tint leaves the motion to the snow. Smooth optical thickness
        // and a narrow edge gradient suggest curved glass without moving smoke.
        // A faint neutral tint gives the globe presence without a heavy gray
        // fill. Keep the interior steady so the particles supply all motion.
        float3 glassTint = float3(0.72,0.72,0.72);
        float opticalDepth = 0.58+0.10*depth;
        float3 glass = mix(background,glassTint,opticalDepth);
        float edgeBend = pow(1.0-depth,4.0);
        glass -= float3(0.022)*edgeBend;
        float3 lightBody = mix(background,glass,inside);
        color = mix(lightBody,color,dark);
    }
    float angle = atan2(p.y,p.x);
    float edgeWidth = 2.0/max(300.0,min(u.viewport.x,u.viewport.y));
    float rim = exp(-pow((r-0.999)/edgeWidth,2.0));
    float arc = 0.1 + 0.75*pow(max(0.0,cos(angle-2.0)),14.0)
                    + 0.25*pow(max(0.0,cos(angle+0.8)),18.0);
    color += mix(float3(-0.23,-0.25,-0.26),float3(0.12,0.17,0.21),dark)*rim*arc;
    float innerRim = exp(-pow((r-0.983)/0.011,2.0));
    color += mix(float3(0.21,0.23,0.24),float3(0.016,0.024,0.030),dark)*innerRim*arc*0.6;
    float topReflection = exp(-pow((r-0.944)/0.016,2.0))*pow(max(0.0,cos(angle-1.9)),32.0);
    color += mix(float3(0.25,0.27,0.29),float3(0.05,0.07,0.08),dark)*topReflection;
    float bottomGlow = exp(-dot((p-float2(0,-0.68))*float2(2.8,9.0),
                               (p-float2(0,-0.68))*float2(2.8,9.0)));
    color += float3(0.009,0.019,0.025)*bottomGlow*dark*(0.5+a*0.5);
    float coverage = globeCoverage(pixelPosition,u);
    return float4(color*coverage,coverage);
}

fragment float4 globeFragment(ScreenVertex in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    return globeSurface(in.uv,in.position.xy,u);
}

// An inverse lens map through a rounded glass wall. Its displacement is tiny
// at the center, peaks in the outer tenth, and rejoins the silhouette at the edge.
// Sampling the completed particle image bends the heads AND their curved trails.
float2 glassRay(float2 p, float strength) {
    float r = length(p);
    if (r <= 0.0001 || r >= 1.0) return p;
    float wall = pow(r,5.0)*sqrt(max(0.0,1.0-r*r));
    return p*(1.0-strength*0.45*wall/r);
}

fragment float4 glassLensFragment(ScreenVertex in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> particles [[texture(0)]],
                                 texture2d<float> desktop [[texture(1)]]) {
    float glassOpacity = u.optics.y;
    constexpr sampler linearSampler(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv = in.position.xy/u.viewport.xy;
    float2 globeScale = min(u.viewport.x,u.viewport.y)*0.445/u.viewport.xy;
    float2 p = (uv-0.5)/globeScale;
    float radius = length(p);
    float2 ray = glassRay(p,u.optics.x);
    float2 particleUV = 0.5+ray*globeScale;
    float4 snow = particles.sample(linearSampler,particleUV);
    float4 body = globeSurface(in.uv,in.position.xy,u);
    float mask = globeCoverage(in.position.xy,u);
    // Grazing reflections strengthen with the wall's optical effect.
    float depth = sqrt(max(0.0,1.0-radius*radius));
    float fresnel = pow(1.0-depth,4.0)*(1.0-smoothstep(0.995,1.005,radius));
    float reflection = u.optics.x*fresnel*(0.018+0.045*pow(max(0.0,-p.x-p.y)*0.707,6.0));
    body.rgb += float3(0.82,0.93,1.0)*reflection;
    float4 glass = body*glassOpacity;
    if (u.optics.z > 0.5 && u.connection.z > 0.5 && radius < 1.005) {
        // Clear glass still lenses the desktop at the full optical strength.
        float2 desktopUV = u.backdropUV.xy+particleUV*u.backdropUV.zw;
        if (all(desktopUV >= 0.0) && all(desktopUV <= 1.0)) {
            float3 behind = desktop.sample(linearSampler,desktopUV).rgb;
            // Composite the captured refracted image once. Using window alpha
            // here would superimpose the undistorted desktop as a second image.
            float3 tinted = mix(behind,body.rgb/max(0.0001,body.a),glassOpacity);
            glass = float4(tinted*mask,mask);
        }
    }
    // The slider changes the glass behind the snow. Particle heads, trails,
    // and their emission keep their own alpha and brightness at every setting.
    snow *= mask;
    return snow+glass*(1.0-snow.a);
}

float3 hsv(float h, float s, float v) {
    float3 rgb = clamp(abs(fract(h+float3(0,2.0/3.0,1.0/3.0))*6.0-3.0)-1.0,0.0,1.0);
    return v*mix(float3(1),rgb,s);
}
float2 project(float3 p) {
    float perspective = 3.8/(3.8-p.z);
    return p.xy*perspective;
}
struct ParticleVertex {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float sparkle;
    float dark;
    float visible;
    float4 pigment; // blue idle body / saturated active pigment, energy
    float bloom;
};

float globePointDiameter(constant Uniforms &u) {
    return min(u.viewport.x,u.viewport.y)*0.89/max(1.0,u.viewport.z);
}

float particleFootprint(constant Uniforms &u) {
    // Match the sprite/trail footprint to the available globe area instead of
    // packing full-size sprites into a shrinking circle. Use logical points
    // so moving between Retina displays does not change the appearance.
    return clamp(globePointDiameter(u)/360.0,0.10,1.0);
}

float bloomVisibility(constant Uniforms &u) {
    float room = smoothstep(90.0,360.0,globePointDiameter(u));
    return mix(1.0,mix(0.25,1.0,room),smoothstep(0.15,0.80,u.timing.z));
}

float speechReturnVisibility(float3 position, uint id, constant Uniforms &u) {
    float depth = position.z+0.06-(float(id%3)-1.0)*0.08;
    // Finish fading on the front shoulder, before the current turns away.
    // The entire return stays at 1%, until it enters the front waveform again.
    float front = smoothstep(0.04,0.14,depth);
    // Expression scales the waves, not rear visibility. Only the final 10%
    // near expression Off restores ordinary currents, with a smooth handoff.
    float speaking = u.speechLight.w*smoothstep(0.0,0.10,u.response.z);
    return mix(mix(1.0,mix(0.01,1.0,front),speaking),1.0,u.speechMode.x);
}

ParticleVertex makeParticleVertex(uint vertexID, uint id,
                                  device const Particle *particles, constant Uniforms &u, constant float2 *speechSamples, bool trailAppearance) {
    Particle p = particles[id];
    float2 corners[] = {float2(-1,-1),float2(1,-1),float2(-1,1),
                        float2(-1,1),float2(1,-1),float2(1,1)};
    float2 uv = corners[vertexID];
    float seed = p.appearance.x, energy = p.appearance.y;
    float flash = p.velocity.w;
    float front = smoothstep(-0.8,0.8,p.position.z);
    float shimmer = 0.5+0.5*drift(u.timing.x*(0.70+seed*0.85)+seed*165.0+19);
    shimmer = mix(0.5,shimmer,u.connection.x);
    float quietSparkle = smoothstep(0.64,0.94,shimmer)*smoothstep(0.68,1.0,p.appearance.z);
    // Independent drifting glints: effort widens the participating population
    // and raises peak brightness, without synchronizing particles into pulses.
    float glintSeed = hash(float(id)+947.0);
    float glintNoise = 0.5+0.5*drift(u.timing.x*(1.25+glintSeed*1.4)+glintSeed*271.0+113.0);
    float threshold = mix(0.87,0.57,u.controls.w);
    float glint = smoothstep(threshold,min(0.99,threshold+0.19),glintNoise)
                *u.controls.w*(0.60+hash(float(id)+1291.0));
    float2 localSpeech = speechAt(speechAge(p.appearance.w,u),speechSamples,u)*u.response.z*speechFacing(p.appearance.w);
    localSpeech = mix(localSpeech,speechAt(liveWaveformAge(id,u),speechSamples,u)*u.response.z,u.speechMode.x);
    float accentSeed = smoothstep(0.35,0.95,hash(float(id)+1871.0));
    float voiceShape = u.speech.w*(localSpeech.x*0.85+localSpeech.y*accentSeed*0.7);
    // Retain the traveling syllable highlights, but the stronger flash follows
    // the sound playing now, independent of the longer waveform history.
    float liveLight = u.speechLight.y*0.50+u.speechLight.z*accentSeed*0.65;
    float historicalGlow = localSpeech.x*0.35+localSpeech.y*accentSeed*0.20;
    float voiceLight = u.speech.w*(min(1.0,u.speechLight.x)*historicalGlow
                                 + u.speechLight.x*liveLight);
    float sparkle = (quietSparkle+glint+voiceLight*0.7)*u.connection.x;
    float radius = (0.66+pow(p.appearance.z,4.0)*0.85)*(0.72+front*0.45);
    radius *= (1.0+0.35*energy+flash*0.9)*(1.0+0.15*glint);
    radius *= mix(1.16,1.0,u.timing.w)*u.controls.y*(1.0+voiceShape*0.16);
    radius *= particleFootprint(u);
    // Quad includes a wide analytic halo; the core is about one logical pixel.
    float quadRadius = radius*5.5*u.viewport.z;
    float2 center = project(p.position.xyz);
    float2 screenVelocity = project(p.position.xyz+p.velocity.xyz*u.motion.y*0.008)-center;
    float velocityLength = length(screenVelocity);
    float2 along = velocityLength > 0.00001 ? screenVelocity/velocityLength : float2(1,0);
    float2 across = float2(-along.y,along.x);
    float stretch = 1.0+min(1.1,velocityLength*55.0)*energy + flash*0.5;
    float2 offset = (along*uv.x*stretch+across*uv.y)*quadRadius;
    float globeRadius = min(u.viewport.x,u.viewport.y)*0.445;
    float2 ndc = (center*globeRadius+offset)*2.0/u.viewport.xy;
    // 76% cool colors, with a smaller gold/coral part of the spectrum.
    float colorSeed = hash(seed*713.0+29.0);
    float hue = colorSeed < 0.76 ? mix(0.46,0.83,colorSeed/0.76) : mix(0.0,0.15,(colorSeed-0.76)/0.24);
    float3 white = float3(0.88,0.94,1.0);
    float3 vivid = hsv(hue,0.72,1.0);
    float3 color = mix(white,vivid,energy);
    float brightness = (0.45+front*0.65)*(1.0+energy*0.5+sparkle*1.2);
    brightness *= (0.88+0.24*shimmer)*(1.0+voiceLight*0.75);
    brightness *= mix(0.45,1.0,u.connection.x);
    float hdrPeak = max(1.0,u.viewport.w);
    brightness += pow(flash,1.8)*(0.7+hdrPeak*0.9);
    brightness += energy*sparkle*max(0.0,hdrPeak-1.0)*0.65;
    float returnVisibility = trailAppearance ? 1.0 : speechReturnVisibility(p.position.xyz,id,u);
    float opacity = p.position.w*mix(0.60+front*0.40,0.35+front*0.65,u.timing.w)*returnVisibility;
    ParticleVertex out;
    out.position = float4(ndc,0,1);
    out.uv = uv;
    color *= brightness;
    // Hue-preserving highlight shoulder follows real display headroom.
    float peak = max(color.r,max(color.g,color.b));
    float knee = hdrPeak*0.72;
    if (peak > knee) {
        float mapped = knee+(hdrPeak-knee)*(1.0-exp(-(peak-knee)/(hdrPeak-knee)));
        color *= mapped/peak;
    }
    // Dense compact globes need less sustained emission as well as narrower
    // halos. Keep the highlight shoulder above SDR for isolated bright glints.
    color *= mix(0.35,1.0,bloomVisibility(u));
    out.color = float4(color,opacity);
    out.sparkle = (sparkle+flash)*returnVisibility;
    out.dark = u.timing.w;
    out.visible = p.position.w;
    float pigmentValue = mix(0.62,0.86,front);
    float3 jewel = hsv(hue,1.0,pigmentValue);
    out.pigment = float4(mix(float3(0.045,0.29,0.66),jewel,energy),energy);
    out.bloom = bloomVisibility(u);
    return out;
}

vertex ParticleVertex particleVertex(uint vertexID [[vertex_id]], uint id [[instance_id]],
                                     device const Particle *particles [[buffer(0)]],
                                     constant Uniforms &u [[buffer(1)]],
                                     constant float2 *speechSamples [[buffer(3)]]) {
    return makeParticleVertex(vertexID,id,particles,u,speechSamples,false);
}

// Look backward through the actual simulated path, interpolating fixed-step
// samples so trail-length changes and variable refresh rates stay smooth.
float4 pathSample(uint id, float age, device const float4 *history, constant Uniforms &u) {
    float bounded = clamp(age,0.0,float(HISTORY_SAMPLES-2));
    uint steps = uint(floor(bounded));
    uint newer = (u.counts.w+HISTORY_SAMPLES-steps)%HISTORY_SAMPLES;
    uint older = (newer+HISTORY_SAMPLES-1)%HISTORY_SAMPLES;
    return mix(history[newer*u.counts.x+id],history[older*u.counts.x+id],fract(bounded));
}

struct TrailVertex {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float3 pigment;
    float dark;
    float fade;
};

vertex TrailVertex trailVertex(uint vertexID [[vertex_id]], uint id [[instance_id]],
                               device const Particle *particles [[buffer(0)]],
                               constant Uniforms &u [[buffer(1)]],
                               device const float4 *history [[buffer(2)]],
                               constant float2 *speechSamples [[buffer(3)]]) {
    Particle p = particles[id];
    if (p.position.w < 0.003) {
        return {float4(2,2,0,1),float2(0),float4(0),float3(0),u.timing.w,0};
    }
    float age = float(vertexID/2)/float(TRAIL_SEGMENTS);
    float side = vertexID%2 == 0 ? -1.0 : 1.0;
    float seed = hash(float(id)+283.0);
    float wanderingLength = 1.0+0.12*drift(u.motion.x*0.24+seed*137.0+47.0);
    float duration = min(float(HISTORY_SAMPLES-2)*u.timing.y,
        u.controls.z*1.5*(0.50+0.65*seed)*wanderingLength*(1.0+u.speech.y*0.22*seed));
    // Stationary traces otherwise stack into luminous curtains of stale audio.
    // Live mode uses a shorter scale: about 0.2 s at the 50% trail setting.
    duration = mix(duration,min(duration,u.controls.z*0.4*(0.7+0.3*seed)*wanderingLength),liveWaveformWeight(u));
    float lookback = age*duration/u.timing.y;
    float4 point = pathSample(id,lookback,history,u);
    float2 center = project(point.xyz);
    float2 tangent = project(pathSample(id,lookback-0.75,history,u).xyz)
                   - project(pathSample(id,lookback+0.75,history,u).xyz);
    float tangentLength = length(tangent);
    float2 normal = tangentLength > 0.000001 ? float2(-tangent.y,tangent.x)/tangentLength : float2(0,1);
    float front = smoothstep(-0.8,0.8,point.z);
    float width = (0.60+0.55*front)*u.controls.y*u.viewport.z*3.0;
    width *= particleFootprint(u);
    width *= mix(1.0,0.48,liveWaveformWeight(u));
    width *= 0.30+0.70*sqrt(max(0.0,1.0-age));
    float globeRadius = min(u.viewport.x,u.viewport.y)*0.445;
    float2 ndc = (center*globeRadius+normal*side*width)*2.0/u.viewport.xy;
    ParticleVertex appearance = makeParticleVertex(0,id,particles,u,speechSamples,true);
    float brightnessSeed = hash(float(id)+619.0);
    float brightness = (0.45+0.80*brightnessSeed)
                     *(0.90+0.24*drift(u.timing.x*0.43+brightnessSeed*173.0+97.0));
    brightness *= mix(1.0,0.25,liveWaveformWeight(u));
    brightness *= pow(bloomVisibility(u),2.0);
    float fade = pow(max(0.0,1.0-age),1.65)*brightness;
    // Dim each historical point by its own depth. The bright front segment
    // remains visible even after its particle head has rounded into the rear.
    fade *= speechReturnVisibility(point.xyz,id,u);
    // Historical visibility prevents trails from appearing behind newly admitted
    // particles. Subpixel paths fade away instead of forming tiny bright knots.
    fade *= min(p.position.w,point.w)*smoothstep(0.0005,0.004,tangentLength*duration/(1.5*u.timing.y));
    return {float4(ndc,0,1),float2(side,age),appearance.color,
            appearance.pigment.rgb,u.timing.w,fade};
}

fragment float4 trailFragment(TrailVertex in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    if (in.fade < 0.001) discard_fragment();
    float across = in.uv.x*in.uv.x;
    float coverage = (exp(-across*28.0)*0.25+exp(-across*5.0)*0.075)*in.fade*in.color.a;
    coverage = min(0.75,coverage);
    float3 darkGlow = in.color.rgb;
    // Saturated bodies keep light-mode tails visible; their narrow luminous
    // core carries a small glint without washing the whole ribbon white.
    float3 lightGlow = mix(in.pigment,in.color.rgb,0.08*exp(-across*45.0));
    return float4(mix(lightGlow,darkGlow,in.dark)*coverage,coverage)*globeCoverage(in.position.xy,u);
}

fragment float4 particleFragment(ParticleVertex in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    if (in.visible < 0.003) discard_fragment();
    float r2 = dot(in.uv,in.uv);
    float core = exp(-r2*75.0)*0.88;
    float halo = exp(-r2*7.0)*0.080*in.bloom;
    float star = (exp(-abs(in.uv.x)*72.0-abs(in.uv.y)*6.0)
                 +exp(-abs(in.uv.y)*72.0-abs(in.uv.x)*6.0))*in.sparkle*0.045*in.bloom;
    float coverage = clamp((core+halo+star)*in.color.a,0.0,0.98);
    float4 darkParticle = float4(in.color.rgb*coverage,coverage);
    float mask = globeCoverage(in.position.xy,u);
    if (in.dark > 0.9999) return darkParticle*mask;

    // Light mode uses pigment plus specular glints, rather than washing the
    // pigment out with its emitted brightness. Idle has a saturated sky-blue body.
    float bodyAlpha = exp(-r2*58.0)*0.96*in.color.a;
    float surroundAlpha = (exp(-r2*23.0)*0.20+exp(-r2*7.0)*0.035)*in.color.a*in.bloom;
    float3 surround = in.pigment.rgb;
    float3 lightColor = in.pigment.rgb*bodyAlpha+surround*surroundAlpha*(1.0-bodyAlpha);
    float lightAlpha = bodyAlpha+surroundAlpha*(1.0-bodyAlpha);
    float glint = clamp(exp(-r2*210.0)*in.sparkle*0.27*in.color.a+star*0.35,0.0,0.65);
    lightColor = lightColor*(1.0-glint)+in.color.rgb*glint;
    lightAlpha += (1.0-lightAlpha)*glint;
    return mix(float4(lightColor,lightAlpha),darkParticle,in.dark)*mask;
}
