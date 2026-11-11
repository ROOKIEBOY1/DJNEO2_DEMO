# Closeup handoff phase recovery

The latest device trace at 12:33 completed and recorded dolly successfully. Handoff started at 45.271; original-subject hover returned at 52.373, consuming 7.1 seconds of the existing eight-second limit. Two 600ms frame reads then failed; the decoder rebuilt only after the entire handoff had already expired.

Give aircraft finishing/hover a 15-second limit. On the first positively verified original-subject hover, begin a separate 15-second picture limit, never exceeding 30 seconds from handoff entry. Set that second deadline once; retries, decoder epochs and individual late frames cannot renew it. Cancellation and expiration have separate messages.

Before requesting a new image, require one second of actual rendered-counter progress in one decoder epoch, with current rendered age at most 500ms and uninterrupted fresh video input. A cached live label, a single frame or a successful keyframe send is insufficient. An absent image or decoder change clears this progress window; wait for stable new output and retry within the same picture deadline.

Observe the existing automatic keyframe policy throughout picture recovery, including output stalls before the decoder has recorded a decode-stall reset. Keep its shared five-second cooldown, three-attempt automatic quota and native pause budget. Do not automatically reopen the decoder or change its C++ implementation.

Keep all subject, flight, control/session generation, stream and after-capture checks. A different confirmed subject or invalid flight/stream context stops continuation. Ordinary-hover candidates still authorize only the existing automatic reselect and strict tracking-confirmation path. No extra user confirmation is introduced; sealed media is preserved on failure.

Deliver a signed HAP in the project root as soon as focused regressions and compilation pass, then finish the full suite. Do not install or send aircraft commands.
