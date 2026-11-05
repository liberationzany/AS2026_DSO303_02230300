// usms-edge-viewer-request
//
// CloudFront trigger point: viewer-request.
// Runs on EVERY request, before the edge cache is consulted. Therefore:
// - it must be fast (5 second hard timeout, 128 MB hard memory cap)
// - it can reject a request without the origin ever being contacted
// - anything it changes about the request becomes part of the cache key
//
// Returns the request object to continue, or a response object to stop.

const AUTH_HEADER = 'x-usms-student';
const PROTECTED_PREFIX = '/transcripts/';

export const handler = async (event) => {
   const request = event.Records[0].cf.request;
   const headers = request.headers;

   // 1. Normalise the URI. Without this, /transcripts/2026/STU-00417.json and
   // /transcripts/2026/stu-00417.json are two different cache entries for one
   // object, which halves the hit rate and doubles the origin traffic.
   request.uri = request.uri.toLowerCase();

   // 2. Anything outside /transcripts/ is not this function's business.
   if (!request.uri.startsWith(PROTECTED_PREFIX)) {
      return request;
   }

   // 3. The USMS portal attaches this header to an authenticated request.
   // Note the [0]: a header value is an ARRAY of {key, value} objects.
   const studentHeader = headers[AUTH_HEADER];
   const studentId = studentHeader && studentHeader[0] && studentHeader[0].value;

   if (!studentId) {
      return {
         status: '403',
         statusDescription: 'Forbidden',
         headers: {
            'content-type': [{ key: 'Content-Type', value: 'application/json' }],
            'cache-control': [{ key: 'Cache-Control', value: 'no-store' }],
            'x-usms-edge': [{ key: 'X-USMS-Edge', value: 'viewer-request-deny' }]
         },
         body: JSON.stringify({
            message: 'transcript access requires an authenticated session'
         })
      };
   }

   // 4. Stamp the request so the origin-response function can see that we ran,
   // and so the trace in Step 16 has something to show.
   request.headers['x-usms-edge'] = [
      { key: 'X-USMS-Edge', value: `viewer-request-allow;student=${studentId.toLowerCase()}` }
   ];

   return request;
};
