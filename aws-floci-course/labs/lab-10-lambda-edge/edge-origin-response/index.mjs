// usms-edge-origin-response
//
// CloudFront trigger point: origin-response.
// Runs after the origin replies and BEFORE the object is cached, so every
// header added here is stored once and served from cache thereafter.
//
// Receives both the request and the response. Returns the response.

const SECURITY_HEADERS = {
    'strict-transport-security': { key: 'Strict-Transport-Security', value: 'max-age=31536000; includeSubDomains' },
    'x-content-type-options': { key: 'X-Content-Type-Options', value: 'nosniff' },
    'x-frame-options':  { key: 'X-Frame-Options',                value: 'DENY' },
    'referrer-policy':  { key: 'Referrer-Policy',                value: 'strict-origin-when-cross-origin' }
};

const TRANSCRIPT_CACHE_CONTROL = 'public, max-age=300, s-maxage=3600';

export const handler = async (event) => {
   const cf = event.Records[0].cf;
   const request = cf.request;
   const response = cf.response;

   // 1. Attach the security headers. Overwrite unconditionally: the origin is a
   // bucket, and a header set on an object by whoever uploaded it is not a
   // security decision we want to inherit.
   for (const name of Object.keys(SECURITY_HEADERS)) {
      response.headers[name] = [SECURITY_HEADERS[name]];
   }

   // 2. Transcripts get a deliberate cache policy: short at the viewer,
   // long at the edge, so a correction propagates in five minutes.
   if (request.uri.startsWith('/transcripts/')) {
      response.headers['cache-control'] = [
         { key: 'Cache-Control', value: TRANSCRIPT_CACHE_CONTROL }
      ];
   }

   // 3. Record whether the viewer-request function ran. In production this is a
   // diagnostic; in this lab it is the evidence that the two functions
   // composed, which is what Step 16 reads.
   const upstream = request.headers['x-usms-edge'];
   response.headers['x-usms-edge-chain'] = [
      {
         key: 'X-USMS-Edge-Chain',
         value: upstream && upstream[0] ? `${upstream[0].value};origin-response` : 'origin-response-only'
      }
   ];

   return response;
};
