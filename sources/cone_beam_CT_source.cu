// GGEMS Copyright (C) 2015

/*!
 * \file cone_beam_CT_source.cu
 * \brief Cone beam source for CT
 * \author Didier Benoit <didier.benoit13@gmail.com>
 * \version 0.1
 * \date Friday January 8, 2015
*/

#include <stdexcept>
#include <algorithm>
#include <cctype>
#include <sstream>
#include <iomanip>
#include <cerrno>
#include <cstring>

#include "ggems_source.cuh"
#include "fun.cuh"
#include "prng.cuh"
#include "cone_beam_CT_source.cuh"

#define POINT_SOURCE_ISOTROPIC 0
#define POINT_SOURCE_BEAM 1

__host__ __device__ void cone_beam_ct_source( ParticlesData particles_data,
  ui32 id, f32 px, f32 py, f32 pz, ui8 direction_option, f32 dx, f32 dy, f32 dz,
  ui8 type, f64 *spectrumE, f64 *spectrumCDF, ui32 nbins, f32 aperture,
  f32 hfoc, f32 vfoc )
{
  if ( direction_option == POINT_SOURCE_ISOTROPIC )
  {
    f32 phi = JKISS32( particles_data, id );
    f32 theta = JKISS32( particles_data, id );

    phi  *= gpu_twopi;
    theta = acosf ( 1.0f - 2.0f * theta );
    particles_data.dx[ id ] = cosf ( phi ) *sinf ( theta );
    particles_data.dy[ id ] = sinf ( phi ) *sinf ( theta );
    particles_data.dz[ id ] = cosf ( theta );
  }
  else if ( direction_option == POINT_SOURCE_BEAM )
  {
    // Get direction
    f32 phi = JKISS32( particles_data, id );
    f32 theta = JKISS32( particles_data, id );
    f32 val_aper = 1.0f - cosf( aperture );
    phi  *= gpu_twopi;
    theta = acosf( 1.0f - val_aper * theta );

    f32 rdx = cosf( phi ) * sinf( theta );
    f32 rdy = sinf( phi ) * sinf( theta );
    f32 rdz = cosf( theta );

    f32xyz d = rotateUz( make_f32xyz( rdx, rdy, rdz ), make_f32xyz ( dx, dy, dz ) );

    particles_data.dx[ id ] = d.x;
    particles_data.dy[ id ] = d.y;
    particles_data.dz[ id ] = d.z;
  }

  // If the source is monochromatic the energy is stored immediately
  if( nbins == 1 )
  {
    particles_data.E[ id ] = spectrumE[ 0 ];
  }
  else
  {
    // Get the position in spectrum
    // Store rndm
    f32 rndm = JKISS32( particles_data, id );
    ui32 pos = binary_search( rndm, spectrumCDF, nbins );

    // Compute an interpolated energy
    f32 cdf0 = spectrumCDF[ pos ];
    f32 cdf1 = spectrumCDF[ pos + 1 ];
    f32 diff_cdf = cdf1 - cdf0;
    f32 ene0 = spectrumE[ pos ];
    f32 ene1 = spectrumE[ pos + 1 ];
    f32 diff_ene = ene1 - ene0;
    particles_data.E[ id ] = ( rndm - cdf0 ) / diff_cdf * diff_ene + ene0;
  }

  // Get 2 randoms for each focal distance
  f32 rndmPosV = JKISS32( particles_data, id );
  f32 rndmPosH = JKISS32( particles_data, id );
  rndmPosV *= vfoc;
  rndmPosH *= hfoc;
  rndmPosV -= vfoc / 2.0;
  rndmPosH -= hfoc / 2.0;

  // set particles
  particles_data.px[ id ] = px;
  particles_data.py[ id ] = py + rndmPosH;
  particles_data.pz[ id ] = pz + rndmPosV;
  particles_data.tof[ id ] = 0.0f;
  particles_data.endsimu[ id ] = PARTICLE_ALIVE;
  particles_data.next_discrete_process[ id ] = NO_PROCESS;
  particles_data.next_interaction_distance[id] = 0.0;
  particles_data.level[ id ] = PRIMARY;
  particles_data.pname[ id ] = type;
  particles_data.geometry_id[ id ] = 0;
  
//   if(id<10)printf("%g %g %g %g %g %g %g \n",spectrumE[ pos ],px,py,pz,particles_data.dx[ id ],particles_data.dy[ id ],particles_data.dz[ id ]);
}

__global__ void kernel_cone_beam_ct_source( ParticlesData particles_data,
  f32 px, f32 py, f32 pz, ui8 direction_option, f32 dx, f32 dy, f32 dz,
  ui8 type, f64 *spectrumE, f64 *spectrumCDF, ui32 nbins, f32 aperture,
  f32 hfoc, f32 vfoc )
{
  const ui32 id = get_id();
  if( id >= particles_data.size ) return;

  cone_beam_ct_source( particles_data, id, px, py, pz, direction_option, dx,
    dy, dz, type, spectrumE, spectrumCDF, nbins, aperture, hfoc, vfoc );
}

ConeBeamCTSource::ConeBeamCTSource()
: GGEMSSource(),
  m_px( 0.0 ),
  m_py( 0.0 ),
  m_pz( 0.0 ),
  m_hfoc( 0.0 ),
  m_vfoc( 0.0 ),
  m_aperture( 360.0 ),
  m_particle_type( PHOTON ),
  m_model_source( "poisson" ),
  m_direction_option( POINT_SOURCE_BEAM ),
  m_dx( 0.0 ),
  m_dy( 0.0 ),
  m_dz( 0.0 ),
  m_spectrumE_h( nullptr ),
  m_spectrumE_d( nullptr ),
  m_spectrumCDF_h( nullptr ),
  m_spectrumCDF_d( nullptr ),
  m_nb_of_energy_bins( 0 )
{
  // Set the name of the source
  set_name( "cone_beam_CT_source" );
}

ConeBeamCTSource::~ConeBeamCTSource()
{
  if( m_spectrumE_h )
  {
    delete[] m_spectrumE_h;
    m_spectrumE_h = nullptr;
  }

  if( m_spectrumCDF_h )
  {
    delete[] m_spectrumCDF_h;
    m_spectrumCDF_h = nullptr;
  }

  if( m_spectrumE_d )
  {
    cudaFree( m_spectrumE_d );
    m_spectrumE_d = nullptr;
  }

  if( m_spectrumCDF_d )
  {
    cudaFree( m_spectrumCDF_d );
    m_spectrumCDF_d = nullptr;
  }
}

void ConeBeamCTSource::set_position( f32 px, f32 py, f32 pz )
{
  m_px = px;
  m_py = py;
  m_pz = pz;
}

void ConeBeamCTSource::set_focal_size( f32 hfoc, f32 vfoc )
{
  m_hfoc = hfoc;
  m_vfoc = vfoc;
}

void ConeBeamCTSource::set_beam_aperture( f32 aperture )
{
  m_aperture = aperture;
}

void ConeBeamCTSource::set_particle_type( std::string pname )
{
  // Transform the name of the particle in small letter
  std::transform( pname.begin(), pname.end(), pname.begin(), ::tolower );

  if( pname == "photon" )
  {
    m_particle_type = PHOTON;
  }
  else if( pname == "electron" )
  {
    m_particle_type = ELECTRON;
  }
  else if( pname == "positron" )
  {
    m_particle_type = POSITRON;
  }
  else
  {
    std::ostringstream oss( std::ostringstream::out );
    oss << "Particle '" << pname << "' not recognized!!!";
    throw std::runtime_error( oss.str() );
  }
}

void ConeBeamCTSource::set_model( std::string model )
{
  // Transform the name of the model in small letter
  std::transform( model.begin(), model.end(), model.begin(), ::tolower );

  m_model_source = model;
}

void ConeBeamCTSource::set_direction( std::string type, f32 vdx, f32 vdy,
  f32 vdz )
{
  // Transform the name of the model in small letter
  std::transform( type.begin(), type.end(), type.begin(), ::tolower );

  if( type == "isotropic" )
  {
    m_direction_option = POINT_SOURCE_ISOTROPIC;
  }
  else if( type == "beam" )
  {
    m_direction_option = POINT_SOURCE_BEAM;
    m_dx = vdx;
    m_dy = vdy;
    m_dz = vdz;

    // Check if the direction is normalized
    if( vdx*vdx + vdy*vdy + vdz*vdz != 1. )
    {
      f32 const norm_distance = std::sqrt( vdx*vdx + vdy*vdy + vdz*vdz );
      m_dx /= norm_distance;
      m_dy /= norm_distance;
      m_dz /= norm_distance;
    }
  }
}

void ConeBeamCTSource::set_mono_energy( f32 energy )
{
  m_spectrumE_h = new f64[ 1 ];
  m_spectrumE_h[ 0 ] = energy;
  m_spectrumCDF_h = new f64[ 1 ];
  m_spectrumCDF_h[ 0 ] = 1.0;
  m_nb_of_energy_bins = 1;
}

void ConeBeamCTSource::set_energy_spectrum( std::string filename )
{
  // Open the histogram file
  std::ifstream input( filename.c_str(), std::ios::in );
  if( !input )
  {
    std::ostringstream oss( std::ostringstream::out );
    #ifdef _WIN32
    char buffer_error[ 256 ];
    oss << "Error opening file '" << filename << "': "
      << strerror_s( buffer_error, 256, errno );
    #else
    oss << "Error opening file '" << filename << "': "
      << strerror( errno );
    #endif
    std::string error_msg = oss.str();
    throw std::runtime_error( error_msg );
  }

  // Compute number of energy bins
  std::string line;
  while( std::getline( input, line ) ) ++m_nb_of_energy_bins;

  // Returning to beginning of the file to read it again
  input.clear();
  input.seekg( 0, std::ios::beg );

  // Allocating buffers to store data
  m_spectrumE_h = new f64[ m_nb_of_energy_bins ];
  m_spectrumCDF_h = new f64[ m_nb_of_energy_bins ];

  // Store data from file
  size_t idx = 0;
  f64 sum = 0.0;
  while( std::getline( input, line ) )
  {
    std::istringstream iss( line );
    iss >> m_spectrumE_h[ idx ] >> m_spectrumCDF_h[ idx ];
    sum += m_spectrumCDF_h[ idx ];
    ++idx;
  }

  // Compute CDF and normalized in same time by security
  m_spectrumCDF_h[ 0 ] /= sum;
  for( ui32 i = 1; i < m_nb_of_energy_bins; ++i )
  {
    m_spectrumCDF_h[ i ] = m_spectrumCDF_h[ i ] / sum
      + m_spectrumCDF_h[ i - 1 ];
  }

  // Watch dog
  m_spectrumCDF_h[ m_nb_of_energy_bins - 1 ] = 1.0;

  // Close the file
  input.close();
}

std::ostream& operator<<( std::ostream& os, ConeBeamCTSource const& cbct )
{
  os << std::setfill( '#' ) << std::setw( 80 ) << "" << GGendl;
  os << "--> Cone-Beam CT source infos:" << GGendl;
  os << "    --------------------------" << GGendl;
  os << GGendl;
  os << "+ Source name:   " << cbct.get_name() << GGendl;
  os << "+ Particle type: "
     << ( cbct.m_particle_type == ELECTRON ? "electron" :
       ( cbct.m_particle_type == PHOTON ? "photon" : "positron" ) )
     << GGendl;
  os << "+ Model:         " << cbct.m_model_source << GGendl;
  os << "+ Aperture:      " << cbct.m_aperture << " [deg]" << GGendl;

  os << GGendl;
  os << "                 " << std::setfill( ' ' ) << std::setw( 12 )
     << "X" << std::setw( 20 )
     << "Y" << std::setw( 20 )
     << "Z" << GGendl;
  os << "+ Position:      " << std::fixed << std::setprecision( 3 )
     << std::setfill( ' ' )
     << std::setw( 15 ) << cbct.m_px/mm << " [mm]"
     << std::setw( 15 ) << cbct.m_py/mm << " [mm]"
     << std::setw( 15 ) << cbct.m_pz/mm << " [mm]" << GGendl;
  os << "+ Direction:     " << std::fixed << std::setprecision( 3 )
     << std::setfill( ' ' )
     << std::setw( 15 ) << cbct.m_dx/mm << "     "
     << std::setw( 15 ) << cbct.m_dy/mm << "     "
     << std::setw( 15 ) << cbct.m_dz/mm << "     " << GGendl;
  os << GGendl;

  os << "+ Energy:        ";

  if( cbct.m_nb_of_energy_bins == 1 )
  {
    os << cbct.m_spectrumE_h[ 0 ]/keV << " [keV] (monoenergy)" << GGendl;
  }
  else if( cbct.m_nb_of_energy_bins == 0 )
  {
    os << GGendl;
  }
  else
  {
    os << "polychromatic spectrum" << GGendl;
    os << GGendl;
    os << "    " << "energy [keV]" << std::setfill( ' ' ) << std::setw( 13 )
       << "CDF" << GGendl;
    for( ui32 i = 0; i < cbct.m_nb_of_energy_bins; ++i )
    {
      os << std::fixed << std::setprecision( 3 ) << std::setfill( ' ' )
         << std::setw( 12 ) << cbct.m_spectrumE_h[ i ]/keV
         << std::setw( 18 ) 
         << cbct.m_spectrumCDF_h[ i ] << GGendl;
    }
  }

  os << std::setfill( '#' ) << std::setw( 80 ) << "";
  return os;
}

void ConeBeamCTSource::initialize( GlobalSimulationParameters params )
{
  // Check if everything was set properly
  if( !m_spectrumCDF_h && !m_spectrumE_h )
  {
    throw std::runtime_error( "Missing parameters for the point source!!!" );
  }

  // Store global parameters
  m_params = params;

  // Handle GPU device
  if( m_params.data_h.device_target == GPU_DEVICE && m_nb_of_energy_bins > 1 )
  {
    // GPU mem allocation
    HANDLE_ERROR( cudaMalloc( (void**)&m_spectrumE_d,
      m_nb_of_energy_bins * sizeof( f64 ) ) );
    HANDLE_ERROR( cudaMalloc( (void**)&m_spectrumCDF_d,
      m_nb_of_energy_bins * sizeof ( f64 ) ) );

    // GPU mem copy
    HANDLE_ERROR ( cudaMemcpy( m_spectrumE_d, m_spectrumE_h,
      sizeof( f64 ) * m_nb_of_energy_bins, cudaMemcpyHostToDevice ) );
    HANDLE_ERROR ( cudaMemcpy( m_spectrumCDF_d, m_spectrumCDF_h,
      sizeof( f64 ) * m_nb_of_energy_bins, cudaMemcpyHostToDevice ) );
  }
}

void ConeBeamCTSource::get_primaries_generator( Particles particles )
{

    GGcout<<__LINE__ << GGendl;
  if( m_params.data_h.device_target == CPU_DEVICE )
  {
    GGcout<<__LINE__ << GGendl;
    ui32 id = 0;
    while( id < particles.size )
    {
      cone_beam_ct_source( particles.data_h, id, m_px, m_py, m_pz,
        m_direction_option, m_dx, m_dy, m_dz, m_particle_type, m_spectrumE_h,
        m_spectrumCDF_h, m_nb_of_energy_bins, m_aperture, m_hfoc, m_vfoc );
      ++id;
    }
  }
  else if( m_params.data_h.device_target == GPU_DEVICE )
  {
    GGcout<<__LINE__ << GGendl;
    GGcout<<__LINE__ << GGendl;
    dim3 threads, grid;
    threads.x = m_params.data_h.gpu_block_size;
    grid.x = ( particles.size + m_params.data_h.gpu_block_size - 1 )
      / m_params.data_h.gpu_block_size;

    kernel_cone_beam_ct_source<<<grid, threads>>>( particles.data_d, m_px, m_py,
      m_pz, m_direction_option, m_dx, m_dy, m_dz, m_particle_type,
      m_spectrumE_d, m_spectrumCDF_d, m_nb_of_energy_bins, m_aperture, m_hfoc,
      m_vfoc );
    cuda_error_check( "Error ", " kernel_cone_beam_ct_source" );
  }
    GGcout<<__LINE__ << GGendl;
}

#undef POINT_SOURCE_ISOTROPIC
#undef POINT_SOURCE_BEAM

