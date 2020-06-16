/*!
  \file GGEMSSolid.cc

  \brief GGEMS class for solid. This class store geometry about phantom or detector

  \author Julien BERT <julien.bert@univ-brest.fr>
  \author Didier BENOIT <didier.benoit@inserm.fr>
  \author LaTIM, INSERM - U1101, Brest, FRANCE
  \version 1.0
  \date Tuesday March 2, 2020
*/

#include "GGEMS/geometries/GGEMSSolid.hh"

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

GGEMSSolid::GGEMSSolid(void)
: solid_data_(nullptr),
  label_data_(nullptr),
  kernel_distance_(nullptr),
  kernel_project_to_(nullptr),
  kernel_track_through_(nullptr)
{
  GGcout("GGEMSSolid", "GGEMSSolid", 3) << "Allocation of GGEMSSolid..." << GGendl;
}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

GGEMSSolid::~GGEMSSolid(void)
{
  GGcout("GGEMSSolid", "~GGEMSSolid", 3) << "Deallocation of GGEMSSolid..." << GGendl;
}
