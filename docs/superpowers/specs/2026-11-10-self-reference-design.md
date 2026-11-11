# Reference photo for first-person subject requests

The user approved using their supplied portrait as the Demo reference for "我". Reuse the current common subject workflow and preserve the existing confirmation and execution gates.

## Approach

Use the fixed supplied photo for this Demo. Keep the JPEG out of Git, include it in the locally built HAP as `rawfile/demo-self-reference.jpg`, and lazily normalize/cache it on the phone. This gives the installed Demo a self-contained reference without adding setup screens. A configurable gallery picker and a dedicated biometric recognition service are later alternatives; neither is needed for this requested fixed photo.

- First-person target wording such as 给我拍、拍我、跟随我、围着我 requests the reference. Helper wording alone such as 帮我起飞 or 帮我给白衣男生拍照 does not.
- Attach the reference only to `subject_selection`, alongside the actual fresh marked camera frame and real candidate IDs. Label reference and current images separately.
- Do not reuse an initial inference's subject ID for a reference request: resolve against the fresh frame plus reference in the common selection stage.
- The model may return only a real candidate ID or `none`. Uncertain, absent or ambiguous matches must not fall back to current/sole/first candidate for a reference request.
- Keep session/generation/cancellation/decoder freshness checks, user confirmation, frozen action parameters and existing execution behavior.
- Missing or invalid reference data fails the reference selection with a clear message. Ordinary requests work unchanged.
- Load and normalize once, preserve orientation, longest edge at most1024, JPEG quality82, bounded source/output sizes; reuse cached normalized data for later requests.
- Do not log image/base64 or embed the portrait in tests or tracked documentation. Do not send the actual portrait to cloud during automated tests.

The user additionally requested removing the two-candidate restriction. Accept variable-count candidate tables using the existing count byte and exact `12 + 12 * count` length, with complete coordinate/ID validation; reject malformed tables rather than truncating them. This is structural decoder support, not proof that the aircraft will report every person in a crowd. A reference picture cannot select unreported candidates.

## Validation

Offline tests for reference routing, labeled dual-image payloads, invalid/missing data, ordinary-request isolation, caching, cancellation and fresh common selection/confirmation. Run the domain suite, review, and build a signed HAP. No autonomous aircraft actions or installation are part of this change.
