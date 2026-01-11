//
//  MoleMenuBar-Bridging-Header.h
//  Bridging header for calling C functions from Go shared library
//

#ifndef MoleMenuBar_Bridging_Header_h
#define MoleMenuBar_Bridging_Header_h

// Import the generated header from the Go shared library
// This will be available after building the library with: make menubar-lib
// The header declares the exported C functions: InitMetrics, GetMetricsJSON, FreeString, CleanupMetrics

// Function prototypes (these match the generated libmolemetrics.h)
extern char* InitMetrics(void);
extern char* GetMetricsJSON(void);
extern void FreeString(char* s);
extern void CleanupMetrics(void);

#endif /* MoleMenuBar_Bridging_Header_h */
