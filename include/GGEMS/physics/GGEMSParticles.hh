#ifndef GUARD_GGEMS_PHYSICS_GGEMSPARTICLES_HH
#define GUARD_GGEMS_PHYSICS_GGEMSPARTICLES_HH

/*!
  \file GGEMSParticles.hh

  \brief Class managing the particles in GGEMS

  \author Julien BERT <julien.bert@univ-brest.fr>
  \author Didier BENOIT <didier.benoit@inserm.fr>
  \author LaTIM, INSERM - U1101, Brest, FRANCE
  \version 1.0
  \date Thrusday October 3, 2019
*/

#include "GGEMS/global/GGEMSConfiguration.hh"
#include "GGEMS/global/GGEMSOpenCLManager.hh"

/*!
  \class GGEMSParticles
  \brief Class managing the particles in GGEMS
*/
class GGEMS_EXPORT GGEMSParticles
{
  public:
    /*!
      \brief GGEMSParticles constructor
    */
    GGEMSParticles(void);

    /*!
      \brief GGEMSParticles destructor
    */
    ~GGEMSParticles(void);

    /*!
      \fn GGEMSParticles(GGEMSParticles const& particle) = delete
      \param particle - reference on the particle
      \brief Avoid copy of the class by reference
    */
    GGEMSParticles(GGEMSParticles const& particle) = delete;

    /*!
      \fn GGEMSParticles& operator=(GGEMSParticles const& particle) = delete
      \param particle - reference on the particle
      \brief Avoid assignement of the class by reference
    */
    GGEMSParticles& operator=(GGEMSParticles const& particle) = delete;

    /*!
      \fn GGEMSParticles(GGEMSParticles const&& particle) = delete
      \param particle - rvalue reference on the particle
      \brief Avoid copy of the class by rvalue reference
    */
    GGEMSParticles(GGEMSParticles const&& particle) = delete;

    /*!
      \fn GGEMSParticles& operator=(GGEMSParticles const&& particle) = delete
      \param particle - rvalue reference on the particle
      \brief Avoid copy of the class by rvalue reference
    */
    GGEMSParticles& operator=(GGEMSParticles const&& particle) = delete;

    /*!
      \fn void Initialize(void)
      \brief Initialize the GGEMSParticles object
    */
    void Initialize(void);

    /*!
      \fn inline cl::Buffer* GetPrimaryParticles() const
      \return pointer to OpenCL buffer storing particles
      \brief return the pointer to OpenCL buffer storing particles
    */
    inline cl::Buffer* GetPrimaryParticles() const {return primary_particles_.get();};

  private:
    /*!
      \fn void AllocatePrimaryParticles(void)
      \brief Allocate memory for primary particles
    */
    void AllocatePrimaryParticles(void);

  private:
    std::shared_ptr<cl::Buffer> primary_particles_; /*!< Pointer storing info about primary particles in batch on OpenCL device */
    GGEMSOpenCLManager& opencl_manager_; /*!< Reference to OpenCL manager singleton */
};

#endif // End of GUARD_GGEMS_PHYSICS_GGEMSPARTICLES_HH
